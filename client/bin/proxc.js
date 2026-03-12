#!/usr/bin/env node

const fs = require("fs");
const fsp = require("fs/promises");
const os = require("os");
const path = require("path");
const https = require("https");
const { spawn, spawnSync } = require("child_process");
const readline = require("readline");

const FRP_VERSION = "0.52.3";
const CONFIG_DIR = path.join(os.homedir(), ".proxc");
const CONFIG_PATH = path.join(CONFIG_DIR, "config.json");
const FRPC_PATH = path.join(CONFIG_DIR, "frpc");
const CACHE_DIR = path.join(os.homedir(), ".cache", "proxc");
const SUBDOMAIN_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

async function main() {
    const [command, ...rest] = process.argv.slice(2);

    if (!command || command === "help" || command === "--help" || command === "-h") {
        printHelp();
        return;
    }

    if (command === "init") {
        await handleConfigure(rest, { fromInitAlias: true });
        return;
    }

    if (command === "config") {
        await handleConfig(rest);
        return;
    }

    await handleTunnel([command, ...rest]);
}

function printHelp() {
    console.log(`Usage:
  proxc config [--server-address <domain>] [--server-port <port>] [--auth-token <token>] [--register-endpoint <url>]
  proxc config show
  proxc <local_port> <subdomain>`);
}

function fail(message, exitCode = 1) {
    console.error(message);
    process.exit(exitCode);
}

function parseArgs(args) {
    const options = {};
    const positionals = [];

    for (let index = 0; index < args.length; index += 1) {
        const arg = args[index];
        if (!arg.startsWith("--")) {
            positionals.push(arg);
            continue;
        }

        const [rawKey, inlineValue] = arg.slice(2).split("=", 2);
        if (inlineValue !== undefined) {
            options[rawKey] = inlineValue;
            continue;
        }

        const next = args[index + 1];
        if (next && !next.startsWith("--")) {
            options[rawKey] = next;
            index += 1;
            continue;
        }

        options[rawKey] = true;
    }

    return { options, positionals };
}

function getOption(options, ...keys) {
    for (const key of keys) {
        if (Object.prototype.hasOwnProperty.call(options, key)) {
            return options[key];
        }
    }
    return undefined;
}

async function handleConfigure(args, { fromInitAlias = false } = {}) {
    const { options } = parseArgs(args);

    if (options.help || options.h) {
        printHelp();
        return;
    }

    if (fromInitAlias) {
        console.error("`proxc init` is deprecated. Use `proxc config`.");
    }

    const existingConfig = await readConfig(false);
    const serverAddress = await resolveConfigValue({
        cliValue: getOption(options, "server-address", "server"),
        currentValue: existingConfig?.serverAddress,
        prompt: "Enter server address (base domain): ",
        required: true,
    });
    const serverPortInput = await resolveConfigValue({
        cliValue: getOption(options, "server-port", "port"),
        currentValue: existingConfig?.serverPort ? String(existingConfig.serverPort) : "7000",
        prompt: "Enter server port: ",
        required: true,
    });
    const authToken = await resolveConfigValue({
        cliValue: getOption(options, "auth-token", "token"),
        currentValue: existingConfig?.authToken ?? "",
        prompt: "Enter auth token (leave blank for none): ",
        required: false,
    });

    const serverPort = parsePort(serverPortInput, "server port");
    const registerEndpointOption = getOption(options, "register-endpoint");
    const defaultRegisterEndpoint = `https://${serverAddress}/_proxc/register`;
    const previousDefaultRegisterEndpoint = existingConfig?.serverAddress
        ? `https://${existingConfig.serverAddress}/_proxc/register`
        : null;
    const registerEndpoint =
        registerEndpointOption ||
        (existingConfig?.registerEndpoint && existingConfig.registerEndpoint !== previousDefaultRegisterEndpoint
            ? existingConfig.registerEndpoint
            : defaultRegisterEndpoint);

    const config = {
        serverAddress,
        serverPort,
        authToken,
        registerEndpoint,
    };

    await writeConfig(config);
    await ensureFrpcBinary();

    console.log(`Client configured at ${CONFIG_PATH}`);
    console.log("Run 'proxc <local_port> <subdomain>' to start a tunnel.");
}

async function handleConfig(args) {
    const [subcommand, ...rest] = args;

    if (!subcommand || subcommand.startsWith("--") || subcommand === "help" || subcommand === "--help" || subcommand === "-h") {
        await handleConfigure(args);
        return;
    }

    if (subcommand !== "show" || rest.length > 0) {
        fail("Usage:\n  proxc config [--server-address <domain>] [--server-port <port>] [--auth-token <token>] [--register-endpoint <url>]\n  proxc config show");
    }

    const config = await readConfig(true);
    console.log(JSON.stringify(config, null, 2));
}

async function handleTunnel(args) {
    if (args.length < 2) {
        fail("Usage: proxc <port> <subdomain>");
    }

    const [portInput, subdomain] = args;
    const config = await readConfig(true);
    const localPort = parsePort(portInput, "local port");

    if (!SUBDOMAIN_RE.test(subdomain)) {
        fail("❌ Invalid subdomain label. Allowed: lowercase letters, numbers, hyphens (no dots, no leading/trailing hyphen).");
    }

    const frpcPath = await ensureFrpcBinary();
    await ensureTunnelRegistered(config, subdomain);
    const configPath = await writeFrpcConfig(config, subdomain, localPort);

    console.log(`🚀 Tunnel started -> https://${subdomain}.${config.serverAddress}`);

    const child = spawn(frpcPath, ["-c", configPath], { stdio: "inherit" });
    const forwardSignal = (signal) => {
        if (!child.killed) {
            child.kill(signal);
        }
    };

    process.on("SIGINT", forwardSignal);
    process.on("SIGTERM", forwardSignal);

    child.on("exit", (code, signal) => {
        if (signal) {
            process.kill(process.pid, signal);
            return;
        }
        process.exit(code ?? 0);
    });
}

async function resolveConfigValue({ cliValue, currentValue, prompt, required }) {
    if (cliValue !== undefined && cliValue !== true) {
        return String(cliValue).trim();
    }

    if (!process.stdin.isTTY) {
        if (required && !currentValue) {
            fail(`❌ Missing required value. Re-run with the needed option or use an interactive terminal.`);
        }
        return currentValue ?? "";
    }

    const suffix = currentValue ? currentValue : "";
    const promptText = suffix && prompt.endsWith(": ")
        ? `${prompt.slice(0, -2)} [${suffix}]: `
        : prompt;
    const answer = await promptLine(promptText);
    if (!answer.trim()) {
        if (required && !suffix) {
            fail("❌ Value is required.");
        }
        return suffix;
    }
    return answer.trim();
}

function promptLine(prompt) {
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
    });

    return new Promise((resolve) => {
        rl.question(prompt, (answer) => {
            rl.close();
            resolve(answer);
        });
    });
}

function parsePort(value, label) {
    const port = Number.parseInt(String(value), 10);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
        fail(`❌ Invalid ${label}: ${value}`);
    }
    return port;
}

async function readConfig(required) {
    try {
        const raw = await fsp.readFile(CONFIG_PATH, "utf8");
        const parsed = JSON.parse(raw);
        if (!parsed.serverAddress || !parsed.serverPort || !parsed.registerEndpoint) {
            throw new Error("config file is incomplete");
        }
        return parsed;
    } catch (error) {
        if (!required && error.code === "ENOENT") {
            return null;
        }
        if (required && error.code === "ENOENT") {
            fail("❌ Missing client config. Run 'proxc config' first.");
        }
        fail(`❌ Failed to read config: ${error.message}`);
    }
}

async function writeConfig(config) {
    await fsp.mkdir(CONFIG_DIR, { recursive: true });
    await fsp.writeFile(CONFIG_PATH, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
    await fsp.chmod(CONFIG_PATH, 0o600);
}

async function ensureTunnelRegistered(config, subdomain) {
    console.log(`🔐 Provisioning HTTPS for ${subdomain}.${config.serverAddress}...`);

    let response;
    try {
        response = await fetch(config.registerEndpoint, {
            method: "POST",
            headers: {
                "Content-Type": "application/x-www-form-urlencoded",
            },
            body: new URLSearchParams({
                subdomain,
                authToken: config.authToken || "",
            }),
        });
    } catch (error) {
        fail(`❌ Failed to reach registration API at ${config.registerEndpoint}: ${error.message}`);
    }

    if (!response.ok) {
        const body = await response.text();
        fail(`❌ Registration failed (${response.status})\n${body}`);
    }
}

async function writeFrpcConfig(config, subdomain, localPort) {
    await fsp.mkdir(CACHE_DIR, { recursive: true });
    const configPath = path.join(CACHE_DIR, `${subdomain}.toml`);
    const toml = `serverAddr = "${config.serverAddress}"
serverPort = ${config.serverPort}

auth.method = "token"
auth.token = "${escapeTomlString(config.authToken || "")}"

[[proxies]]
name = "${escapeTomlString(subdomain)}"
type = "http"
localIP = "127.0.0.1"
localPort = ${localPort}
subdomain = "${escapeTomlString(subdomain)}"
`;
    await fsp.writeFile(configPath, toml, "utf8");
    return configPath;
}

function escapeTomlString(value) {
    return String(value).replaceAll("\\", "\\\\").replaceAll("\"", "\\\"");
}

async function ensureFrpcBinary() {
    if (await isExecutable(FRPC_PATH)) {
        return FRPC_PATH;
    }

    await fsp.mkdir(CONFIG_DIR, { recursive: true });
    const archiveName = resolveFrpArchiveName();
    const tmpDir = await fsp.mkdtemp(path.join(os.tmpdir(), "proxc-frp-"));
    const archivePath = path.join(tmpDir, archiveName);

    console.log(`Downloading FRP ${FRP_VERSION} (${archiveName})...`);
    await downloadFile(
        `https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${archiveName}`,
        archivePath
    );

    const extract = spawnSync("tar", ["-xzf", archivePath, "-C", CONFIG_DIR, "--strip-components=1"], {
        stdio: "inherit",
    });

    if (extract.status !== 0) {
        fail("❌ Failed to extract FRP archive. Ensure 'tar' is available.");
    }

    await fsp.chmod(FRPC_PATH, 0o755);
    await fsp.rm(tmpDir, { recursive: true, force: true });
    return FRPC_PATH;
}

async function isExecutable(filePath) {
    try {
        await fsp.access(filePath, fs.constants.X_OK);
        return true;
    } catch {
        return false;
    }
}

function resolveFrpArchiveName() {
    const platformMap = {
        linux: {
            x64: "linux_amd64",
            arm64: "linux_arm64",
        },
        darwin: {
            x64: "darwin_amd64",
            arm64: "darwin_arm64",
        },
    };

    const platformTargets = platformMap[process.platform];
    const target = platformTargets?.[process.arch];
    if (!target) {
        fail(`❌ Unsupported platform: ${process.platform}/${process.arch}`);
    }

    return `frp_${FRP_VERSION}_${target}.tar.gz`;
}

async function downloadFile(url, destination) {
    await new Promise((resolve, reject) => {
        const request = https.get(url, (response) => {
            if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
                response.resume();
                downloadFile(response.headers.location, destination).then(resolve).catch(reject);
                return;
            }

            if (response.statusCode !== 200) {
                response.resume();
                reject(new Error(`unexpected status ${response.statusCode}`));
                return;
            }

            const file = fs.createWriteStream(destination);
            response.pipe(file);
            file.on("finish", () => {
                file.close(resolve);
            });
            file.on("error", reject);
        });

        request.on("error", reject);
    });
}

main().catch((error) => {
    fail(`❌ ${error.message}`);
});
