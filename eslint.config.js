// Flat config baseline for a TypeScript repository (madhani-ts-coding-standard).
// Copy to the repo root as eslint.config.js and add the framework plugin
// (react-hooks, next) on top. Prettier stays last so it can disable
// formatting rules.
import eslint from "@eslint/js";
import prettier from "eslint-config-prettier";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: [
      "eslint.config.js",
      "dist/**",
      "build/**",
      ".next/**",
      "coverage/**",
      "node_modules/**",
    ],
  },
  eslint.configs.recommended,
  tseslint.configs.recommendedTypeChecked,
  {
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
    rules: {
      "no-console": "error",
      "@typescript-eslint/consistent-type-imports": ["error", { fixStyle: "inline-type-imports" }],
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/no-non-null-assertion": "error",
      "@typescript-eslint/no-floating-promises": "error",
      "@typescript-eslint/no-misused-promises": "error",
      "@typescript-eslint/ban-ts-comment": [
        "error",
        { "ts-expect-error": "allow-with-description" },
      ],
      "@typescript-eslint/explicit-module-boundary-types": "error",
      "no-restricted-syntax": [
        "error",
        {
          selector: "TSAsExpression > TSAnyKeyword",
          message: "Never cast to any; write a type guard or parse with zod.",
        },
        {
          selector: "TSAsExpression > TSUnknownKeyword",
          message: "Never cast through unknown; fix the declared type.",
        },
        {
          selector: "TSEnumDeclaration",
          message: "Use an `as const` object or a union of literals instead of enum.",
        },
        {
          selector: "ExportDefaultDeclaration",
          message: "Use named exports unless the framework requires a default export.",
        },
      ],
    },
  },
  {
    // Framework-required default exports.
    files: [
      "**/*.config.{js,mjs,ts}",
      "**/app/**/{page,layout,loading,error,not-found,template,route,robots,sitemap}.{ts,tsx}",
      "**/routes/**/*.tsx",
    ],
    rules: { "no-restricted-syntax": "off" },
  },
  {
    files: ["**/*.test.{ts,tsx}"],
    rules: { "@typescript-eslint/no-non-null-assertion": "off" },
  },
  prettier,
);
