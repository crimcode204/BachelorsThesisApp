import shaka from "shaka-player";

declare global {
  interface Window {
    streamLog: (log: any) => void;
    setStartupDelay: (delay: number) => void;
  }
}

const manifestUri: string = "http://127.0.0.1:3000/video/bbb.mpd";
const player = new shaka.Player();
const startTime = performance.now();

/* let metricsLog: {
  startupDelay: number | null;
  logs: {
    timestamp: number;
    event: string;
    estimatedBandwidth: number;
    currentBitrate: number;
    bufferLength: number;
    isBuffering: boolean;
  }[];
} = {
  startupDelay: null,
  logs: [],
}; */
let isCurrentlyBuffering: boolean = false;

setInterval(() => {
  const stats = player.getStats();
  const timestamp = performance.now() - startTime;

  const log = {
    timestamp: Number(timestamp.toFixed(2)),
    event: "POLL",
    estimatedBandwidth: stats.estimatedBandwidth,
    currentBitrate: stats.streamBandwidth,
    bufferLength: Number(player.getBufferFullness().toFixed(2)),
    isBuffering: isCurrentlyBuffering,
  };

  if (window.streamLog) {
    window.streamLog(log);
  } else {
    console.log(log);
  }
}, 500);

player.addEventListener("loaded", () => {
  const delay = performance.now() - startTime;
  if (window.setStartupDelay) {
    window.setStartupDelay(delay);
  } else {
    console.log(`Startup delay: ${delay}`);
  }
});

player.addEventListener("buffering", (event: any) => {
  const stats = player.getStats();
  const timestamp = performance.now() - startTime;
  isCurrentlyBuffering = event.buffering;

  const log = {
    timestamp: Number(timestamp.toFixed(2)),
    event: isCurrentlyBuffering ? "BUFFER_START" : "BUFFER_END",
    estimatedBandwidth: stats.estimatedBandwidth,
    currentBitrate: stats.streamBandwidth,
    bufferLength: Number(player.getBufferFullness().toFixed(2)),
    isBuffering: isCurrentlyBuffering,
  };

  if (window.streamLog) {
    window.streamLog(log);
  } else {
    console.log(log);
  }
});

player.addEventListener("adaptation", () => {
  const stats = player.getStats();
  const timestamp = performance.now() - startTime;

  const log = {
    timestamp: Number(timestamp.toFixed(2)),
    event: "ADAPTATION",
    estimatedBandwidth: stats.estimatedBandwidth,
    currentBitrate: stats.streamBandwidth,
    bufferLength: Number(player.getBufferFullness().toFixed(2)),
    isBuffering: isCurrentlyBuffering,
  };

  if (window.streamLog) {
    window.streamLog(log);
  } else {
    console.log(log);
  }
});

async function initPlayer() {
  const videoElement: HTMLVideoElement =
    document.querySelector("#videoPlayer")!;
  player.attach(videoElement);

  player.configure({
    streaming: {
      retryParameters: {
        maxAttempts: 10,
        baseDelay: 1000,
        timeout: 0,
      },
    },
  });

  try {
    await player.load(manifestUri);
    console.log("Video loaded");
  } catch (e) {
    console.error("Error loading manifest", e);
  }
}

initPlayer();
