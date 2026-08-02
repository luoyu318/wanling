export function buildDiff(toolName: string, input: Record<string, unknown>, _output: string): string {
  if (toolName === "edit") {
    const oldStr = (input.oldString as string) || ""
    const newStr = (input.newString as string) || ""
    if (!oldStr && !newStr) return ""
    const oldLines = oldStr.split("\n").map(l => `- ${l}`)
    const newLines = newStr.split("\n").map(l => `+ ${l}`)
    return [...oldLines, ...newLines].join("\n")
  }
  if (toolName === "write") {
    const content = (input.content as string) || ""
    if (!content) return ""
    return content.split("\n").map(l => `+ ${l}`).join("\n")
  }
  return ""
}
