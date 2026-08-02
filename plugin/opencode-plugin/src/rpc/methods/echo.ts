type EchoParams = { text?: string }

export const echoHandler = async (params: unknown): Promise<{ echo: string }> => {
  const p = (params ?? {}) as EchoParams
  return { echo: p.text ?? "" }
}
