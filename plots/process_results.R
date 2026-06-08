library(jsonlite)
library(purrr)
library(dplyr)

results_dir <- "../results"
sub_dirs <- list.dirs(results_dir, recursive = FALSE)
suite_list <- sub_dirs[grep("test_suite_", sub_dirs)]

if (length(suite_list) == 0) {
  stop("No test suites found")
}

dir_info_list <- file.info(suite_list)
suite <- rownames(dir_info_list)[which.max(dir_info_list$mtime)]
print(paste("Processing test data in ", suite))

algorithms <- c("cubic", "bbr")
test_cases <- c(
  "ideal",
  "lossy",
  "jittery",
  "lfn",
  "staircase",
  "periodic_lossy"
)

client_data_frame <- data.frame()
server_data_frame <- data.frame()
startup_delay_data <- data.frame()
rep_client_data <- data.frame()
rep_server_data <- data.frame()

for (test_case in test_cases) {
  for (cca in algorithms) {
    # Client data processing
    client_pattern <- paste0("client_", cca, "_", test_case, "_run.*\\.json")
    client_files <- list.files(
      suite,
      pattern = client_pattern,
      full.names = TRUE
    )

    if (length(client_files) == 0) {
      stop(paste("Client data for", cca, "+", test_case, "missing"))
    }

    client_raw <- client_files |>
      map_df(
        ~ {
          data <- fromJSON(.x)
          df <- as.data.frame(data$logs)
          if (nrow(df) == 0) {
            return(NULL)
          }
          df$run_id <- .x
          return(df)
        }
      ) |>
      mutate(
        algorithm = toupper(cca),
        test_case = test_case,
        time_sec = timestamp / 1000,
        bandwidth_mbps = estimatedBandwidth / 1000000,
        bitrate_mbps = currentBitrate / 1000000,
        time_bin = floor(time_sec),
        true_capacity = case_when(
          test_case == "ideal" ~ 20,
          test_case == "lossy" ~ 5,
          test_case == "jittery" ~ 5,
          test_case == "lfn" ~ 50,
          test_case == "periodic_lossy" ~ 5,

          test_case == "staircase" ~ c(
            5,
            2,
            0.9,
            0.5,

            0.9,
            0.9,
            2,
            2,

            5,
            5,
            5,
            2,

            0.9,
            0.5,
            0.9,
            0.9,

            2,
            2,
            5,
            5
          )[pmin(floor(time_bin / 15) + 1, 20)],

          TRUE ~ NA_real_
        )
      )

    client_stats <- client_raw |>
      group_by(time_bin, algorithm, test_case) |>
      summarize(
        mean_bw = mean(bandwidth_mbps, na.rm = TRUE),
        sd_bw = sd(bandwidth_mbps, na.rm = TRUE),
        mean_bitrate = mean(bitrate_mbps, na.rm = TRUE),
        mean_buffer = mean(bufferLength, na.rm = TRUE),
        true_capacity = first(true_capacity),
        .groups = "drop"
      )
    client_data_frame <- bind_rows(client_data_frame, client_stats)

    run_medians <- client_raw |>
      group_by(run_id) |>
      summarize(run_median_bw = median(bandwidth_mbps, na.rm = TRUE))

    grand_median <- median(run_medians$run_median_bw, na.rm = TRUE)
    champion_client_id <- run_medians |>
      mutate(diff = abs(run_median_bw - grand_median)) |>
      slice_min(order_by = diff, n = 1, with_ties = FALSE) |>
      pull(run_id)
    rep_client_data <- bind_rows(
      rep_client_data,
      client_raw |> filter(run_id == champion_client_id)
    )
    champion_run_num <- sub(".*_run([0-9]+)\\.json", "\\1", champion_client_id)

    delay_data <- client_files |>
      map_df(
        ~ {
          data <- fromJSON(.x)
          delay <- if (!is.null(data$startupDelay)) data$startupDelay else NA

          logs_df <- as.data.frame(data$logs)
          stalls <- if (nrow(logs_df) > 0) {
            sum(logs_df$event == "BUFFER_START", na.rm = TRUE)
          } else {
            0
          }

          data.frame(
            run_id = basename(.x),
            algorithm = toupper(cca),
            test_case = test_case,
            startup_delay_ms = delay,
            stall_count = stalls
          )
        }
      )
    startup_delay_data <- bind_rows(startup_delay_data, delay_data)

    # Server data processing
    server_pattern <- paste0("network_", cca, "_", test_case, "_run.*\\.txt")
    server_files <- list.files(
      suite,
      pattern = server_pattern,
      full.names = TRUE
    )

    if (length(server_files) == 0) {
      stop(paste("Server data for", cca, "+", test_case, "missing"))
    }

    server_raw <- server_files |>
      map_df(
        ~ {
          df <- tryCatch(
            {
              lines <- readLines(.x, warn = FALSE)

              timestamps <- numeric()
              cwnds <- numeric()
              rtts <- numeric()
              pacing_rates <- numeric()
              bytes <- numeric()
              current_ts <- NA

              for (line in lines) {
                if (grepl("^[0-9]{13}$", trimws(line))) {
                  current_ts <- as.numeric(trimws(line))
                } else if (grepl("cwnd:[0-9]+", line) & !is.na(current_ts)) {
                  val_cwnd <- as.numeric(sub(".*cwnd:([0-9]+).*", "\\1", line))
                  val_rtt <- as.numeric(sub(".*rtt:([0-9.]+).*", "\\1", line))

                  pacing_raw <- sub(
                    ".*pacing_rate ([0-9.]+[a-zA-Z]+).*",
                    "\\1",
                    line
                  )
                  val_pacing <- case_when(
                    grepl("Gbps", pacing_raw) ~ as.numeric(sub(
                      "Gbps",
                      "",
                      pacing_raw
                    )) *
                      1e9,
                    grepl("Mbps", pacing_raw) ~ as.numeric(sub(
                      "Mbps",
                      "",
                      pacing_raw
                    )) *
                      1e6,
                    grepl("Kbps", pacing_raw) ~ as.numeric(sub(
                      "Kbps",
                      "",
                      pacing_raw
                    )) *
                      1e3,
                    TRUE ~ as.numeric(gsub("[^0-9.]", "", pacing_raw))
                  )

                  if (grepl("bytes_sent:[0-9]+", line)) {
                    bytes_val <- as.numeric(sub(
                      ".*bytes_sent:([0-9]+).*",
                      "\\1",
                      line
                    ))
                  } else {
                    bytes_val <- 0
                  }

                  timestamps <- c(timestamps, current_ts)
                  cwnds <- c(cwnds, val_cwnd)
                  rtts <- c(rtts, val_rtt)
                  pacing_rates <- c(pacing_rates, val_pacing)
                  bytes <- c(bytes, bytes_val)
                }
              }

              if (length(timestamps) == 0) {
                return(NULL)
              }

              start_ts <- min(timestamps, na.rm = TRUE)
              timestamps <- timestamps - start_ts

              df <- data.frame(
                timestamp = timestamps,
                cwnd = cwnds,
                rtt = rtts,
                pacing_rate = pacing_rates,
                bytes_sent = bytes
              ) |>
                group_by(timestamp) |>
                slice_max(order_by = bytes_sent, n = 1, with_ties = FALSE) |>
                ungroup() |>
                select(timestamp, cwnd, rtt, pacing_rate)

              df$run_id <- basename(.x)
              return(df)
            },
            error = function(e) {
              stop(paste("Error parsing file:", .x))
            }
          )

          if (is.null(df) || nrow(df) == 0) {
            return(NULL)
          }
          return(df)
        }
      )
    if (!is.null(server_raw)) {
      server_raw <- server_raw |>
        mutate(
          algorithm = toupper(cca),
          test_case = test_case,
          time_sec = timestamp / 1000,
          time_bin = floor(time_sec)
        )

      server_stats <- server_raw |>
        group_by(time_bin, algorithm, test_case) |>
        summarize(
          mean_cwnd = mean(cwnd, na.rm = TRUE),
          mean_pacing_rate = mean(pacing_rate, na.rm = TRUE),
          mean_rtt = mean(rtt, na.rm = TRUE),
          sd_cwnd = sd(cwnd, na.rm = TRUE),
          .groups = "drop"
        )
      server_data_frame <- bind_rows(server_data_frame, server_stats)

      champion_server_id <- paste0(
        "network_",
        cca,
        "_",
        test_case,
        "_run",
        champion_run_num,
        ".txt"
      )
      rep_server_data <- bind_rows(
        rep_server_data,
        server_raw |> filter(run_id == champion_server_id)
      )
    }
  }
}

# Export formatted data
client_out <- file.path(suite, "processed_client_data.csv")
server_out <- file.path(suite, "processed_server_data.csv")
st_delay_out <- file.path(suite, "processed_st_delays.csv")
rep_client_out <- file.path(suite, "processed_rep_client_data.csv")
rep_server_out <- file.path(suite, "processed_rep_server_data.csv")

write.csv(client_data_frame, client_out, row.names = FALSE)
write.csv(server_data_frame, server_out, row.names = FALSE)
write.csv(startup_delay_data, st_delay_out, row.names = FALSE)
write.csv(rep_client_data, rep_client_out, row.names = FALSE)
write.csv(rep_server_data, rep_server_out, row.names = FALSE)

print(paste("Data successfully processed, results in:", suite))
