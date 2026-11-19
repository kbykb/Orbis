package com.orbising.orbis

import java.net.URLEncoder

/** A local notification only names an existing session and the public pairing identity. */
internal data class NotificationOpenTarget(
    val hostId: String,
    val sessionId: String,
    val deviceId: String,
    val hostPub: String,
) {
    val intentData: String
        get() = "orbis://notification/" + listOf(hostId, sessionId, deviceId, hostPub).joinToString("/") {
            URLEncoder.encode(it, "UTF-8").replace("+", "%20")
        }

    fun matches(pairing: HostPairing): Boolean =
        hostId == pairing.hostId && deviceId == pairing.deviceId && hostPub == pairing.hostPub

    fun destination(state: RemoteState): NotificationOpenDestination? {
        if (state.connection != RelayConnection.ONLINE || !state.e2eReady || !state.homeDirectoryReceived) return null
        val live = state.runtimes.values.filter { it.sessionId == sessionId }
        if (live.size == 1) return NotificationOpenDestination.Runtime(live.single().runtimeId)
        if (live.size > 1) return NotificationOpenDestination.Home
        if (state.runtimes.values.any { it.sessionId.isNullOrBlank() }) return null
        return if (state.sessions[sessionId]?.hasHistoryCache == true) NotificationOpenDestination.History(sessionId)
        else NotificationOpenDestination.Home
    }

    companion object {
        fun create(pairing: HostPairing, sessionId: String?): NotificationOpenTarget? =
            create(pairing.hostId, sessionId, pairing.deviceId, pairing.hostPub)

        fun create(hostId: String?, sessionId: String?, deviceId: String?, hostPub: String?): NotificationOpenTarget? {
            val fields = listOf(hostId, sessionId, deviceId, hostPub)
            if (fields.any { it.isNullOrBlank() || it.toByteArray(Charsets.UTF_8).size > 4096 }) return null
            return NotificationOpenTarget(hostId!!, sessionId!!, deviceId!!, hostPub!!)
        }
    }
}

internal sealed interface NotificationOpenDestination {
    data class Runtime(val runtimeId: String) : NotificationOpenDestination
    data class History(val sessionId: String) : NotificationOpenDestination
    data object Home : NotificationOpenDestination
    data object Invalid : NotificationOpenDestination
}

/** Main-thread ownership: a newer click or explicit navigation supersedes an old wait. */
internal class NotificationOpenQueue {
    private var generation = 0L
    private var target: NotificationOpenTarget? = null

    fun enqueue(next: NotificationOpenTarget): Long {
        target = next
        return ++generation
    }

    fun cancel() {
        ++generation
        target = null
    }

    fun resolve(token: Long, pairing: HostPairing, state: RemoteState, expired: Boolean = false): NotificationOpenDestination? {
        if (token != generation) return null
        val pending = target ?: return null
        val result = when {
            !pending.matches(pairing) -> NotificationOpenDestination.Invalid
            expired -> NotificationOpenDestination.Home
            else -> pending.destination(state)
        }
        if (result != null) target = null
        return result
    }
}
