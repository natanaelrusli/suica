export type LogLevel = "debug" | "info" | "warn" | "error";
export type LogAttributes = Readonly<Record<string, string | number | boolean | null>>;

export interface Logger {
  debug(message: string, attributes?: LogAttributes): void;
  info(message: string, attributes?: LogAttributes): void;
  warn(message: string, attributes?: LogAttributes): void;
  error(message: string, attributes?: LogAttributes): void;
}

export interface LoggerOptions {
  readonly serviceName: string;
  readonly environment: string;
  readonly minLevel: LogLevel;
  readonly write: (line: string) => void;
  readonly now: () => Date;
}

const SERVICE_NAME = "mr-review-assistant";
const LEVEL_ORDER: Readonly<Record<LogLevel, number>> = { debug: 0, info: 1, warn: 2, error: 3 };

function writeToStdout(line: string): void {
  process.stdout.write(`${line}\n`);
}

function levelFromEnv(): LogLevel {
  const value = process.env["MRA_LOG_LEVEL"];
  return value === "debug" || value === "info" || value === "warn" || value === "error"
    ? value
    : "info";
}

export function createLogger(overrides: Partial<LoggerOptions> = {}): Logger {
  const options: LoggerOptions = {
    serviceName: SERVICE_NAME,
    environment: process.env["MRA_ENV"] ?? "local",
    minLevel: levelFromEnv(),
    write: writeToStdout,
    now: () => new Date(),
    ...overrides,
  };

  const emit = (level: LogLevel, message: string, attributes?: LogAttributes): void => {
    if (LEVEL_ORDER[level] < LEVEL_ORDER[options.minLevel]) return;
    options.write(
      JSON.stringify({
        timestamp: options.now().toISOString(),
        level,
        message,
        service_name: options.serviceName,
        environment: options.environment,
        ...(attributes === undefined ? {} : { attributes }),
      }),
    );
  };

  return {
    debug: (message, attributes) => {
      emit("debug", message, attributes);
    },
    info: (message, attributes) => {
      emit("info", message, attributes);
    },
    warn: (message, attributes) => {
      emit("warn", message, attributes);
    },
    error: (message, attributes) => {
      emit("error", message, attributes);
    },
  };
}
