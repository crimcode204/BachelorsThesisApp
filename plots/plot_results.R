suppressPackageStartupMessages({
  library(ggplot2)
  library(dplyr)
  library(patchwork)
  library(scales)
  library(svglite)
})

results_dir <- "../results"
sub_dirs <- list.dirs(results_dir, recursive = FALSE)
suite_list <- sub_dirs[grep("test_suite_", sub_dirs)]

if (length(suite_list) == 0) {
  stop("No test suites found")
}

dir_info_list <- file.info(suite_list)
suite <- rownames(dir_info_list)[which.max(dir_info_list$mtime)]
print(paste("Plotting using results in ", suite))

client_data <- read.csv(file.path(suite, "processed_client_data.csv"))
server_data <- read.csv(file.path(suite, "processed_server_data.csv"))
rep_client_data <- read.csv(file.path(suite, "processed_rep_client_data.csv"))
rep_server_data <- read.csv(file.path(suite, "processed_rep_server_data.csv"))

algorithm_colors <- c("CUBIC" = "#E41A1C", "BBR" = "#377EB8")

test_cases <- unique(client_data$test_case)

for (current_case in test_cases) {
  if (current_case %in% c("lossy", "periodic_lossy")) {
    df_client <- rep_client_data |>
      filter(test_case == current_case) |>
      mutate(
        mean_bw = bandwidth_mbps,
        sd_bw = 0,
        mean_bitrate = bitrate_mbps,
        mean_buffer = bufferLength
      )
    df_server <- rep_server_data |>
      filter(test_case == current_case) |>
      mutate(
        mean_cwnd = cwnd,
        mean_pacing_rate = ifelse(algorithm == "CUBIC", NA, pacing_rate),
        mean_rtt = rtt,
        sd_cwnd = 0
      )
  } else {
    df_client <- client_data |> filter(test_case == current_case)
    df_server <- server_data |>
      filter(test_case == current_case) |>
      mutate(
        mean_pacing_rate = ifelse(algorithm == "CUBIC", NA, mean_pacing_rate)
      )
  }

  if (nrow(df_client) == 0) {
    next
  }

  max_cwnd <- max(df_server$mean_cwnd, na.rm = TRUE)
  max_pacing <- max(df_server$mean_pacing_rate, na.rm = TRUE) / 1e6
  max_capacity <- max(df_client$true_capacity, na.rm = TRUE)
  throughput_ceiling <- ifelse(is.finite(max_capacity), max_capacity * 1.5, 100)
  transport_coeff <- ifelse(
    is.finite(max_cwnd) && is.finite(max_pacing) && max_pacing > 0,
    max_cwnd / max_pacing,
    10
  )

  # Client throughput
  p_throughput <- ggplot(
    df_client,
    aes(x = time_bin, group = algorithm, color = algorithm)
  ) +
    geom_ribbon(
      aes(
        ymin = pmax(0, mean_bw - sd_bw),
        ymax = mean_bw + sd_bw,
        fill = algorithm
      ),
      alpha = 0.1,
      color = NA
    ) +
    geom_line(
      aes(y = mean_bw, linetype = "Est. Bandwidth"),
      linewidth = 0.8,
      alpha = 0.6
    ) +
    geom_step(
      aes(y = mean_bitrate, linetype = "Chosen Bitrate"),
      linewidth = 1.2
    ) +
    geom_step(
      aes(y = true_capacity, linetype = "True Capacity"),
      color = "black",
      linewidth = 1,
      alpha = 0.8
    ) +
    coord_cartesian(ylim = c(0, throughput_ceiling)) +
    scale_color_manual(values = algorithm_colors) +
    scale_fill_manual(values = algorithm_colors) +
    scale_linetype_manual(
      values = c(
        "Est. Bandwidth" = "solid",
        "Chosen Bitrate" = "twodash",
        "True Capacity" = "dotted"
      )
    ) +
    labs(
      title = paste("Scenario:", toupper(current_case)),
      subtitle = "TCP BBR vs CUBIC",
      x = "",
      y = "Throughput\n(Mbps)",
      color = "Algorithm",
      fill = "Algorithm",
      linetype = "Metric"
    ) +
    theme_minimal() +
    theme(legend.position = "top", axis.text.x = element_blank())

  # Server cwnd
  p_cwnd <- ggplot(
    data = df_server,
    aes(x = time_bin, y = mean_cwnd, color = algorithm),
  ) +
    geom_line(
      linewidth = 0.8
    ) +
    scale_color_manual(values = algorithm_colors) +
    labs(x = "", y = "CWND\n(Segments)") +
    theme_minimal() +
    theme(legend.position = "none", axis.text.x = element_blank())

  p_rtt <- ggplot(
    df_server,
    aes(x = time_bin, y = mean_rtt, color = algorithm),
  ) +
    geom_line(
      linewidth = 0.8
    ) +
    scale_color_manual(values = algorithm_colors) +
    labs(x = "", y = "RTT\n(ms)") +
    theme_minimal() +
    theme(legend.position = "none", axis.text.x = element_blank())

  # Server pacing rate (BBR only)
  p_pacing <- ggplot() +
    geom_line(
      data = df_server |> filter(algorithm == "BBR" & !is.na(mean_pacing_rate)),
      aes(x = time_bin, y = mean_pacing_rate / 1e6, color = algorithm),
      linewidth = 1.0
    ) +
    geom_step(
      data = df_client,
      aes(x = time_bin, y = true_capacity, linetype = "True Capacity"),
      color = "black",
      linewidth = 0.8,
      alpha = 0.8
    ) +
    scale_color_manual(values = algorithm_colors) +
    scale_linetype_manual(values = c("True Capacity" = "dotted")) +
    # coord_cartesian(ylim = c(0, throughput_ceiling)) +
    labs(x = "", y = "BBR Pacing\n(Mbps)", linetype = "Network") +
    theme_minimal() +
    theme(legend.position = "none", axis.text.x = element_blank())

  # Client buffer health
  p_buffer <- ggplot(
    df_client,
    aes(x = time_bin, y = mean_buffer, color = algorithm),
  ) +
    geom_line(
      linewidth = 1
    ) +
    scale_color_manual(values = algorithm_colors) +
    labs(x = "Time (Seconds)", y = "Buffer Fullness\n(Ratio)") +
    theme_minimal() +
    theme(legend.position = "none")

  # Stack all 3 plots on top of each other
  stacked_plot <- p_throughput /
    p_cwnd /
    p_rtt /
    p_pacing /
    p_buffer +
    plot_layout(heights = c(3, 1.5, 1.5, 1.5, 1.5), guides = "collect") +
    plot_annotation(theme = theme(legend.position = "top"))

  # Export stacked plots
  dest_file <- file.path(suite, paste0("plot_", current_case, ".svg"))
  ggsave(dest_file, plot = stacked_plot, width = 12, height = 7, bg = "white")
}

# Startup delay plots
st_delay_data <- read.csv(file.path(suite, "processed_st_delays.csv"))

high_delay_cases <- c("lfn", "jittery")
df_high <- st_delay_data |> filter(test_case %in% high_delay_cases)
df_norm <- st_delay_data |> filter(!(test_case %in% high_delay_cases))

generate_st_delay_plot <- function(
  data_set,
  title_suffix,
  y_min,
  y_max,
  y_step
) {
  ggplot(
    data_set,
    aes(x = toupper(test_case), y = startup_delay_ms, fill = algorithm) # nolint
  ) +
    geom_boxplot(
      position = position_dodge(width = 0.8),
      alpha = 0.7,
      outlier.shape = NA
    ) +
    geom_point(
      aes(color = algorithm),
      position = position_jitterdodge(jitter.width = 0.15, dodge.width = 0.8),
      size = 2,
      alpha = 0.8
    ) +
    scale_fill_manual(values = algorithm_colors) +
    scale_color_manual(values = algorithm_colors) +
    scale_y_continuous(
      limits = c(y_min, y_max),
      oob = scales::squish,
      breaks = seq(y_min, y_max, by = y_step)
    ) +
    labs(
      title = "Startup Delay",
      subtitle = "TCP BBR vs CUBIC",
      x = "Network Scenario",
      y = "Startup Delay (ms)",
      fill = "Algorithm",
      color = "Algorithm"
    ) +
    theme_minimal() +
    theme(
      legend.position = "top",
      plot.title = element_text(face = "bold", size = 14),
      axis.text.x = element_text(face = "bold", size = 11),
      panel.grid.major.x = element_blank()
    )
}

p_st_delay_norm <- generate_st_delay_plot(
  df_norm,
  "No latency networks",
  20,
  80,
  10
)
ggsave(
  file.path(suite, "plot_st_delays_normal.svg"),
  plot = p_st_delay_norm,
  width = 10,
  height = 6,
  bg = "white"
)

p_st_delay_high <- generate_st_delay_plot(
  df_high,
  "High latency networks",
  1200,
  1800,
  100
)
ggsave(
  file.path(suite, "plot_st_delays_high.svg"),
  plot = p_st_delay_high,
  width = 7,
  height = 6,
  bg = "white"
)

# Stalling summary plot
p_stalls <- ggplot(
  st_delay_data,
  aes(x = toupper(test_case), y = stall_count, fill = algorithm)
) +
  geom_boxplot(
    position = position_dodge(width = 0.8),
    alpha = 0.7,
    outlier.shape = NA
  ) +
  geom_point(
    aes(color = algorithm),
    position = position_jitterdodge(jitter.width = 0.15, dodge.width = 0.8),
    size = 2,
    alpha = 0.8
  ) +
  scale_fill_manual(values = algorithm_colors) +
  scale_color_manual(values = algorithm_colors) +
  labs(
    title = "Video Stalling Events",
    subtitle = "",
    x = "Network Scenario",
    y = "Number of Stalls",
    fill = "Algorithm",
    color = "Algorithm",
  ) +
  theme_minimal() +
  theme(
    legend.position = "top",
    plot.title = element_text(face = "bold", size = 14),
    axis.text.x = element_text(face = "bold", size = 11),
    panel.grid.major.x = element_blank()
  )

ggsave(
  file.path(suite, "plot_stalling_events.svg"),
  plot = p_stalls,
  width = 10,
  height = 6,
  bg = "white"
)

print(paste("Successfully generated plots in", suite))
