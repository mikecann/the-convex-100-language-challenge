export const approvedTargetRuntimeCommands = new Map([
  ["javascript", new Set(["node"])],
  ["python", new Set(["python", "python3"])],
]);

export function targetRuntimeError(languageId, manifest) {
  const command = manifest.targetRuntimeCommand;
  const approved = approvedTargetRuntimeCommands.get(languageId);

  if (manifest.implementation?.status === "planned") {
    return command
      ? `${languageId}: planned client must not declare a target runtime command`
      : null;
  }

  if (approved && !approved.has(command)) {
    return `${languageId}: implemented client must declare its approved target runtime command`;
  }

  if (command && !approved?.has(command)) {
    return `${languageId}: target runtime command is not approved for this language`;
  }

  return null;
}
