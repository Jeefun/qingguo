export type ModuleHost = (method: string, argsJson: string, respond: (responseJson: string) => void) => void;

export function run(
  code: string,
  sourceId: string,
  method: string,
  argsJson: string,
  host: ModuleHost
): Promise<string>;
