# TCP BBR (v1) vs CUBIC

### Video streaming testbed

\
A mostly automated testbed for comparing the two congestion control algorithms in a video streaming context.

The tests extract and showcase the following metrics:

- transport layer related:
  - CWND
  - Pacing Rate
  - RTT
- application layer related:
  - Estimated Throughput
  - Bitrate
  - Buffer Health
  - Startup Time
  - Stall Count

## Requirements

Packages: `podman bun R ffmpeg`

R libraries: `ggplot2 dplyr patchwork svglite jsonlite`

```R
install.packages(c("ggplot2", "dplyr", "patchwork", "svglite", "jsonlite"))
```

Linux kernel modules: `bbr` \
Has to be loaded. \
Does not need to be set as congestion control algorithm, as it will only be applied inside the container.

## Architecture

### Server

Rust file server with Axum inside a Podman container

### Client

Typescript web server with Shaka video player
Exposes 2 methods for metrics harvesting

### Test runner

Typescript bun server:

- runs the web page inside a headless chrome session
- runs the server and applies `tc` rules based on the network scenario
- listens for client metrics
- polls the container's exposed socket every 0.5 seconds
- exports the metrics for the client (json) and network (filtered `ss` output)

### Plotting scripts

R scripts, one for processing data into .csv files and one for the plots:

- one plot for each scenario and the relevant data over a 5 minute interval
- 2 plots for the startup delay in each scenario (one for scenarios with delay, one for the rest)
- one plot for the stall frequency in each scenario

### Control script

Used for:

- Encoding the video used for testing
- Building the server container
- Launching the server container with the specified congestion control algorithm
- Applying the Trafic Control (`tc`) custom profiles
- Running the testbed (Test runner + Plotting scripts)

### Outputs

Json client logs, `ss` dumps, processed csv files and the plots are stored in timestamped folders inside './results' \
Running the pipeline through the ctl exports the plots to './result_plots/'

## Usage

1. Encode the video used for testing (must be at least 5 minutes)

```bash
./testbedctl encode my_video.mp4
```

2. Build the server container

```bash
./testbedctl server build
```

3. Run the test suite

```bash
# If no number is given it will run 5 iterations
./testbedctl run 10
```

To see all commands, use

```bash
./testbedctl help
```

## Methodology

Testing consists of one or more iterations. \
During an iteration the video is run for 5 minutes with each network scenario and each congestion control algorithm. \
Each iteration takes about 1 hour to run.

At the end the data for each network scenario + congestion control algorithm are averaged out and plotted. \
Lossy and Periodic Lossy are an exception. For these, a median run is chosen to be showcased.

### Network scenarios:

- Ideal - 20Mbps bandwidth, no other restrictions
- Jittery - 5Mbps bandwidth, 50ms (±20ms) packet delay
- LFN - 50Mbps bandwidth, 100ms packet delay
- Lossy - 5Mbps bandwidth, 2% packet loss rate
- Periodic Lossy - 5Mbps bandwidth, 2% packet loss rate for a 15s interval every minute
- Staircase - 5Mbps, 2Mbps, 900Kbps and 500Kbps bandwidths, alterating every 15 seconds in ascending/descending order
