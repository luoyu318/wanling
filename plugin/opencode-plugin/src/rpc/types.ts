export class RPCError extends Error {
  constructor(public code: number, message: string) {
    super(message)
    this.name = "RPCError"
  }
}
