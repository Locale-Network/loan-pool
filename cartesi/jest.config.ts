import type { Config } from "jest";

const config: Config = {
  preset: "ts-jest",
  testEnvironment: "node",
  testMatch: ["**/*.spec.ts"],
  verbose: true,
  moduleFileExtensions: ["ts", "js"],
  transform: {
    "^.+\\.ts$": [
      "ts-jest",
      {
        tsconfig: {
          strict: true,
          noUncheckedIndexedAccess: false,
          esModuleInterop: true,
          moduleResolution: "node",
          target: "ES2022",
          skipLibCheck: true,
        },
      },
    ],
  },
};

export default config;
