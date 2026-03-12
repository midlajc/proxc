#!/usr/bin/env node

import * as fs from "node:fs";
import { promises as fsp } from "node:fs";
import * as https from "node:https";
import * as os from "node:os";
import * as path from "node:path";
import * as readline from "node:readline";
import { spawn, spawnSync } from "node:child_process";

const FRP_VERSION = "0.52.3";
const CONFIG_DIR = path.join(os.homedir(), ".proxc");
const CONFIG_PATH = path.join(CONFIG_DIR, "config.json");
const FRPC_PATH = path.join(CONFIG_DIR, "frpc");
const CACHE_DIR = path.join(os.homedir(), ".cache", "proxc");
const SUBDOMAIN_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

interface ClientConfig {
    serverAddress: string;
    serverPort: number;
    authToken: string;
    registerEndpoint: string;
}

type CliOptions = Record<string, string | boolean>;

interface ParsedArgs {
    options: CliOptions;
    positionals: string[];
}

interface ResolveConfigValueArgs {
    cliValue: string | boolean | undefined;
    currentValue?: string;
    prompt: string;
    required: boolean;
}

async function main(): Promise<void> {
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

function printHelp(): void {
    console.log(`Usage:
  proxc config [--server-address <domain>] [--server-port <port>] [--auth-token <token>] [--register-endpoint <url>]
  proxc config show
  proxc <local_port> <subdomain>`);
}

function fail(message: string, exitCode = 1): never {
    console.error(message);
    process.exit(exitCode);
}

function parseArgs(args: string[]): ParsedArgs {
    const options: CliOptions = {};
    const positionals: string[] = [];

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

function getOption(options: CliOptions, ...keys: string[]): string | boolean | undefined {
    for (const key of keys) {
        if (Object.prototype.hasOwnProperty.call(options, key)) {
            return options[key];
        }
    }

    return undefined;
}

async function handleConfigure(
    args: string[],
    { fromInitAlias = false }: { fromInitAlias?: boolean } = {}
): Promise<void> {
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
        typeof registerEndpointOption === "string"
            ? registerEndpointOption
            : existingConfig?.registerEndpoint &&
                existingConfig.registerEndpoint !== previousDefaultRegisterEndpoint
              ? existingConfig.registerEndpoint
              : defaultRegisterEndpoint;

    const config: ClientConfig = {
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

async function handleConfig(args: string[]): Promise<void> {
    const [subcommand, ...rest] = args;

    if (!subcommand || subcommand.startsWith("--") || subcommand === "help" || subcommand === "--help" || subcommand === "-h") {
        await handleConfigure(args);
        return;
    }

    if (subcommand !== "show" || rest.length > 0) {
        fail(
            "Usage:\n  proxc config [--server-address <domain>] [--server-port <port>] [--auth-token <token>] [--register-endpoint <url>]\n  proxc config show"
        );
    }

    const config = await readConfig(true);
    console.log(JSON.stringify(config, null, 2));
}

async function handleTunnel(args: string[]): Promise<void> {
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
    const forwardSignal = (signal: NodeJS.Signals): void => {
        if (!child.killed) {
            child.kill(signal);
        }
    };

    process.on("SIGINT", forwardSignal);
    process.on("SIGTERM", forwardSignal);

    child.on("exit", (code: number | null, signal: NodeJS.Signals | null) => {
        if (signal) {
            process.kill(process.pid, signal);
            return;
        }

        process.exit(code ?? 0);
    });
}

async function resolveConfigValue({
    cliValue,
    currentValue,
    prompt,
    required,
}: ResolveConfigValueArgs): Promise<string> {
    if (cliValue !== undefined && cliValue !== true) {
        return String(cliValue).trim();
    }

    if (!process.stdin.isTTY) {
        if (required && !currentValue) {
            fail("❌ Missing required value. Re-run with the needed option or use an interactive terminal.");
        }

        return currentValue ?? "";
    }

    const suffix = currentValue ?? "";
    const promptText = suffix && prompt.endsWith(": ") ? `${prompt.slice(0, -2)} [${suffix}]: ` : prompt;
    const answer = await promptLine(promptText);
    if (!answer.trim()) {
        if (required && !suffix) {
            fail("❌ Value is required.");
        }

        return suffix;
    }

    return answer.trim();
}

function promptLine(prompt: string): Promise<string> {
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

function parsePort(value: string, label: string): number {
    const port = Number.parseInt(String(value), 10);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
        fail(`❌ Invalid ${label}: ${value}`);
    }

    return port;
}

async function readConfig(required: true): Promise<ClientConfig>;
async function readConfig(required: false): Promise<ClientConfig | null>;
async function readConfig(required: boolean): Promise<ClientConfig | null> {
    try {
        const raw = await fsp.readFile(CONFIG_PATH, "utf8");
        const parsed = JSON.parse(raw) as Partial<ClientConfig>;
        if (!parsed.serverAddress || !parsed.serverPort || !parsed.registerEndpoint) {
            throw new Error("config file is incomplete");
        }

        return {
            serverAddress: parsed.serverAddress,
            serverPort: parsed.serverPort,
            authToken: parsed.authToken ?? "",
            registerEndpoint: parsed.registerEndpoint,
        };
    } catch (error: unknown) {
        const nodeError = error as NodeJS.ErrnoException;
        if (!required && nodeError.code === "ENOENT") {
            return null;
        }

        if (required && nodeError.code === "ENOENT") {
            fail("❌ Missing client config. Run 'proxc config' first.");
        }

        const message = error instanceof Error ? error.message : String(error);
        fail(`❌ Failed to read config: ${message}`);
    }
}

async function writeConfig(config: ClientConfig): Promise<void> {
    await fsp.mkdir(CONFIG_DIR, { recursive: true });
    await fsp.writeFile(CONFIG_PATH, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
    await fsp.chmod(CONFIG_PATH, 0o600);
}

async function ensureTunnelRegistered(config: ClientConfig, subdomain: string): Promise<void> {
    console.log(`🔐 Provisioning HTTPS for ${subdomain}.${config.serverAddress}...`);

    let response: Response;
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
    } catch (error: unknown) {
        const message = error instanceof Error ? error.message : String(error);
        fail(`❌ Failed to reach registration API at ${config.registerEndpoint}: ${message}`);
    }

    if (!response.ok) {
        const body = await response.text();
        fail(`❌ Registration failed (${response.status})\n${body}`);
    }
}

async function writeFrpcConfig(config: ClientConfig, subdomain: string, localPort: number): Promise<string> {
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

function escapeTomlString(value: string): string {
    return String(value).replaceAll("\\", "\\\\").replaceAll("\"", "\\\"");
}

async function ensureFrpcBinary(): Promise<string> {
    if (await isExecutable(FRPC_PATH)) {
        return FRPC_PATH;
    }

    await fsp.mkdir(CONFIG_DIR, { recursive: true });
    const archiveName = resolveFrpArchiveName();
    const tmpDir = await fsp.mkdtemp(path.join(os.tmpdir(), "proxc-frp-"));
    const archivePath = path.join(tmpDir, archiveName);

    console.log(`Downloading FRP ${FRP_VERSION} (${archiveName})...`);
    await downloadFile(`https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${archiveName}`, archivePath);

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

async function isExecutable(filePath: string): Promise<boolean> {
    try {
        await fsp.access(filePath, fs.constants.X_OK);
        return true;
    } catch {
        return false;
    }
}

function resolveFrpArchiveName(): string {
    const platformMap: Partial<Record<NodeJS.Platform, Partial<Record<NodeJS.Architecture, string>>>> = {
        linux: {
            x64: "linux_amd64",
            arm64: "linux_arm64",
        },
        darwin: {
            x64: "darwin_amd64",
            arm64: "darwin_arm64",
        },
    };

    const target = platformMap[process.platform]?.[process.arch];
    if (!target) {
        fail(`❌ Unsupported platform: ${process.platform}/${process.arch}`);
    }

    return `frp_${FRP_VERSION}_${target}.tar.gz`;
}

async function downloadFile(url: string, destination: string): Promise<void> {
    await new Promise<void>((resolve, reject) => {
        const request = https.get(url, (response) => {
            if (response.statusCode && response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
                response.resume();
                void downloadFile(response.headers.location, destination).then(resolve).catch(reject);
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
                file.close();
                resolve();
            });
            file.on("error", reject);
        });

        request.on("error", reject);
    });
}

void main().catch((error: unknown) => {
    const message = error instanceof Error ? error.message : String(error);
    fail(`❌ ${message}`);
});
