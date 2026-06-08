import { chromium } from "playwright";
import { $ } from "bun";

const setupScript = "../testbedctl";
const clientUrl = "http://localhost:5173";
const containerName = "video-stream-server";

enum CongestionControlAlgorithm {
  CUBIC = "cubic",
  BBR = "bbr",
}

enum TestCase {
  Ideal = "ideal",
  Lossy = "lossy",
  Jittery = "jittery",
  LongFatNetwork = "lfn",

  Staircase = "staircase",
  PeriodicLossy = "periodic_lossy",
}

async function sleepProtected(ms: number, page: any, browser: any) {
  return new Promise((resolve, reject) => {
    let killCheck: NodeJS.Timeout;

    const timer = setTimeout(() => {
      clearInterval(killCheck);
      resolve(undefined);
    }, ms);

    const cleanupAndReject = (msg: string) => {
      clearTimeout(timer);
      clearInterval(killCheck);
      reject(new Error(msg));
    };

    page.once("crash", () => cleanupAndReject("Page crashed"));
    browser.once("disconnected", () =>
      cleanupAndReject("Browser disconnected"),
    );
    killCheck = setInterval(async () => {
      try {
        await $`pgrep -f "headless"`.quiet();
      } catch (e) {
        cleanupAndReject("Browser killed");
      }
    }, 2000);
  });
}

async function executeTestCaseNetwork(
  testCase: TestCase,
  page: any,
  browser: any,
) {
  switch (testCase) {
    case TestCase.Ideal:
    case TestCase.Lossy:
    case TestCase.Jittery:
    case TestCase.LongFatNetwork:
      await $`${setupScript} network ${testCase}`;
      await sleepProtected(15000 * 4 * 5, page, browser);
      break;
    case TestCase.Staircase:
      const sequence = [
        "medium_bw",
        "lower_bw",
        "low_bw",
        "lowest_bw",

        "low_bw",
        "low_bw",
        "lower_bw",
        "lower_bw",

        "medium_bw",
        "medium_bw",
        "medium_bw",
        "lower_bw",

        "low_bw",
        "lowest_bw",
        "low_bw",
        "low_bw",

        "lower_bw",
        "lower_bw",
        "medium_bw",
        "medium_bw",
      ];
      for (const bw of sequence) {
        await $`${setupScript} network ${bw}`;
        await sleepProtected(15000, page, browser);
      }
      break;
    case TestCase.PeriodicLossy:
      for (let i = 0; i < 5; i++) {
        await $`${setupScript} network medium_bw`;
        await sleepProtected(15000 * 2, page, browser);
        await $`${setupScript} network lossy`;
        await sleepProtected(15000, page, browser);
        await $`${setupScript} network medium_bw`;
        await sleepProtected(15000, page, browser);
      }
      break;
  }
}

// Main testing loop
async function runTest(
  cca: CongestionControlAlgorithm,
  testCase: TestCase,
  suiteDir: String,
  run: number,
  browser: any,
) {
  console.log(`\nStarting test: ${cca} + ${testCase}`);

  const clientLogFile = `${suiteDir}/client_${cca}_${testCase}_run${run}.json`;
  const networkLogFile = `${suiteDir}/network_${cca}_${testCase}_run${run}.txt`;

  // Start container
  await $`${setupScript} server ${cca}`.quiet();

  // Set initial network rule
  if (testCase === TestCase.Staircase || testCase === TestCase.PeriodicLossy) {
    await $`${setupScript} network medium_bw`;
  } else {
    await $`${setupScript} network ${testCase}`;
  }

  // Spawn server socket poller
  const socketPoller = Bun.spawn(
    [
      "bash",
      "-c",
      `while true; do
        date +%s%3N >> ${networkLogFile}
        podman exec ${containerName} ss -ti '( sport = :3000 )' >> ${networkLogFile}
        sleep 0.5
      done`,
    ],
    { stdout: "ignore", stderr: "ignore" },
  );

  // Launch browser context
  const context = await browser.newContext();
  const page = await context.newPage();

  const metrics = {
    startupDelay: null as number | null,
    logs: [] as any[],
  };
  let prematureStop: boolean = false;

  try {
    // Set up metrics harvest
    await page.exposeFunction("streamLog", (metric: any) => {
      metrics.logs.push(metric);
    });
    await page.exposeFunction("setStartupDelay", (delay: number) => {
      metrics.startupDelay = delay;
    });

    // Launch video page
    await page.goto(clientUrl, {
      waitUntil: "domcontentloaded",
      timeout: 60000,
    });

    // Wait 3 mins
    // Change network rules during this time depending on the test case
    await executeTestCaseNetwork(testCase, page, browser);
  } catch (e: any) {
    prematureStop = true;
    console.error(`Test stopped: ${e.message}`);
  }

  // Export client metrics
  await Bun.write(clientLogFile, JSON.stringify(metrics, null, 2));

  // Cleanup
  await page.close();
  await context.close();
  socketPoller.kill("SIGKILL");
  await $`${setupScript} server stop`.quiet();

  if (!prematureStop) {
    console.log(`Test ended successfully`);
  }
}

async function main() {
  let runsArg = Bun.argv[2];
  const totalRuns = typeof runsArg !== "undefined" ? parseInt(runsArg) : 5;
  if (Number.isNaN(totalRuns)) {
    console.log(`Usage: ${Bun.argv[1]} [num_of_runs]`);
    process.exit(1);
  }

  console.log(`Starting test suite: ${totalRuns} iterations`);

  await $`mkdir -p ../results`;

  const suiteId = Date.now();
  const suiteDir = `../results/test_suite_${suiteId}`;
  await $`mkdir -p ${suiteDir}`;

  console.log("Launching client web server");
  const clientProcess = Bun.spawn(["bun", "run", "dev"], {
    cwd: "../client",
    stdout: "ignore",
    stderr: "ignore",
  });

  const browser = await chromium.launch({
    headless: true,
    args: [
      "--autoplay-policy=no-user-gesture-required",
      "--mute-audio",
      "--disable-dev-shm-usage",
      "--disable-gpu-compositing",
    ],
  });

  const algorithms = Object.values(CongestionControlAlgorithm);
  const testCases = Object.values(TestCase);
  let exit_flag: number = 0;

  try {
    for (let run = 1; run <= totalRuns; run++) {
      console.log(`\nIteration ${run}/${totalRuns}`);
      for (const testCase of testCases) {
        for (const algorithm of algorithms) {
          await runTest(algorithm, testCase, suiteDir, run, browser);
        }
      }
    }
    console.log("\nAll test completed");
  } catch (e) {
    exit_flag = 1;
    console.log(e);
  } finally {
    clientProcess.kill();

    await browser.close();
    await clientProcess.exited;

    process.exit(exit_flag);
  }
}

main();
