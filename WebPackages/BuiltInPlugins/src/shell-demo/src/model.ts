//
//  Copyright (c) 2026 Viva Republica, Inc.
//

export const defaultCommand = "/usr/bin/printf 'Hello from Necto Shell Demo\\n'";
export const unapprovedCommand = "/usr/bin/printf 'This exact command was not approved\\n'";

export interface ShellExecutionResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export function executionRows(result: ShellExecutionResult): [string, string | number][] {
  return [
    ["stdout", result.stdout || "—"],
    ["stderr", result.stderr || "—"],
    ["exitCode", result.exitCode],
  ];
}
