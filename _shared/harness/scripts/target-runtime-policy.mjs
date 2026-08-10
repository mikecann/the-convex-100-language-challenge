// A language earns an entry here only when the named command is the interpreter
// that genuinely executes that language's own client code. Languages that
// compile to JavaScript have no other execution target, so node is that
// interpreter for them exactly as it is for JavaScript itself; the Convex
// protocol behaviour still has to be written in the target language.
export const approvedTargetRuntimeCommands = new Map([
  ["coffeescript", new Set(["node"])],
  ["fennel", new Set(["lua"])],
  ["hy", new Set(["python3"])],
  ["javascript", new Set(["node"])],
  ["lua", new Set(["lua"])],
  ["php", new Set(["php"])],
  ["python", new Set(["python", "python3"])],
  ["rescript", new Set(["node"])],
  ["typescript", new Set(["node"])],
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
