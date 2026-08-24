import { WanlingClient, RPCDispatcher } from "wanling-sdk"

const serverUrl = process.env.WANLING_SERVER_URL ?? "http://localhost:18008"
const agentId = process.env.WANLING_AGENT_ID ?? ""
const secretKey = process.env.WANLING_SECRET_KEY ?? ""

const client = new WanlingClient({ serverUrl, agentId, secretKey })

const dispatcher = new RPCDispatcher()
dispatcher.register("echo", async (params) => ({ echoed: params }))
client.attachDispatcher(dispatcher)

client.on("connected", () => console.log("[template] connected"))
client.on("message", async (msg) => {
  console.log("[template] message", msg.conversation_id, msg.content)
  client.sendTypedMessage(msg.conversation_id, "markdown", { text: "你好,我是模板 agent" })
})

client.on("error", (err) => console.error("[template] error", err))
client.on("fatal", (event, err) => { console.error("[template] fatal", event, err); process.exit(1) })

await client.connect()
