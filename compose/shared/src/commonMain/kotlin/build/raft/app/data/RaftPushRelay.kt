package build.raft.app.data

import build.raft.app.network.RaftKtorCallKind
import build.raft.app.network.RaftKtorProcessClients
import build.raft.app.network.RaftRequestPriority
import build.raft.app.raftLogInfo
import build.raft.app.raftLogWarn
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.content.TextContent
import io.ktor.http.isSuccess
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * Self-build (xuheng-li 2026-10-31): Raft pushes only to its own app, so anyRaft takes Raft's Web
 * Push instead. The relay (push.vgent.dev on claw-server) gives this device a Web Push endpoint and
 * keys; the app subscribes them at Raft with its own session, which never leaves the phone; the
 * relay forwards each push to APNs with the message link, which a tap opens.
 */
internal object RaftPushRelay {
    private const val RegisterUrl = "https://push.vgent.dev/register"
    private const val LogTag = "RaftPushRelay"
    private val json = Json { ignoreUnknownKeys = true }
    private var endpoint: String? = null

    suspend fun subscribe(networkClient: RaftNetworkClient, registrationJson: String) {
        runCatching {
            val registration = json.parseToJsonElement(registrationJson).jsonObject
            if (registration["provider"]?.jsonPrimitive?.content != "apns") return
            val request = buildJsonObject {
                put("token", registration["deviceToken"]?.jsonPrimitive?.content.orEmpty())
                put("env", registration["env"]?.jsonPrimitive?.content ?: "production")
            }
            val response =
                RaftKtorProcessClients.provider
                    .client(RaftRequestPriority.Background, RaftKtorCallKind.NonIdempotent)
                    .post(RegisterUrl) { setBody(TextContent(request.toString(), ContentType.Application.Json)) }
            if (!response.status.isSuccess()) {
                raftLogWarn(LogTag, "relay_register_failed status=${response.status.value}")
                return
            }
            val device = json.parseToJsonElement(response.bodyAsText()).jsonObject
            val subscription = buildJsonObject {
                put("endpoint", device.getValue("endpoint"))
                putJsonObject("keys") {
                    put("p256dh", device.getValue("p256dh"))
                    put("auth", device.getValue("auth"))
                }
            }
            val result =
                networkClient.request(
                    priority = DataRequestPriority.Background,
                    path = "push/subscribe",
                    method = "POST",
                    bodyText = subscription.toString()
                )
            if (result.isSuccessful) endpoint = device.getValue("endpoint").jsonPrimitive.content
            raftLogInfo(LogTag, "subscribe code=${result.code}")
        }.onFailure { raftLogWarn(LogTag, "subscribe_failed ${it::class.simpleName}") }
    }

    suspend fun unsubscribe(networkClient: RaftNetworkClient) {
        val current = endpoint ?: return
        endpoint = null
        runCatching {
            val result =
                networkClient.request(
                    priority = DataRequestPriority.Foreground,
                    path = "push/subscribe",
                    method = "DELETE",
                    bodyText = buildJsonObject { put("endpoint", current) }.toString()
                )
            raftLogInfo(LogTag, "unsubscribe code=${result.code}")
        }
    }
}
