package com.orbising.orbis

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationNavigationTest {
    private val pairing = HostPairing(
        hostId = "host/one", hostPub = "pub+key", pskRoot = "secret",
        relayUrl = "https://relay", deviceId = "phone/one", credential = "credential",
    )

    @Test fun `notification data is unique and encodes target fields`() {
        val a = NotificationOpenTarget.create(pairing, "session/one")!!
        val b = NotificationOpenTarget.create(pairing, "session/two")!!
        assertNotEquals(a.intentData, b.intentData)
        assertTrue(a.intentData.contains("host%2Fone/session%2Fone/phone%2Fone/pub%2Bkey"))
        assertNotEquals(a.intentData, NotificationOpenTarget.create(pairing.copy(deviceId = "other"), "session/one")!!.intentData)
    }

    @Test fun `notification waits for authenticated directory and resolves live runtime`() {
        val target = NotificationOpenTarget.create(pairing, "session")!!
        val incomplete = RemoteState(connection = RelayConnection.ONLINE, e2eReady = true)
        assertNull(target.destination(incomplete))
        val state = incomplete.copy(
            homeDirectoryReceived = true,
            runtimes = mapOf("runtime" to RuntimeSummary("runtime", "Agent", "/repo", "running", sessionId = "session")),
        )
        assertEquals(NotificationOpenDestination.Runtime("runtime"), target.destination(state))
        assertNull(target.destination(state.copy(connection = RelayConnection.RECONNECTING)))
        assertNull(target.destination(state.copy(e2eReady = false)))
    }

    @Test fun `runtime replacement follows stable session and ambiguous sessions go home`() {
        val target = NotificationOpenTarget.create(pairing, "session")!!
        val old = RuntimeSummary("old", "Agent", "/repo", "running", sessionId = "unrelated")
        val current = old.copy(runtimeId = "new", sessionId = "session")
        val ready = RemoteState(connection = RelayConnection.ONLINE, e2eReady = true, homeDirectoryReceived = true,
            runtimes = mapOf(old.runtimeId to old, current.runtimeId to current))
        assertEquals(NotificationOpenDestination.Runtime("new"), target.destination(ready))
        assertEquals(NotificationOpenDestination.Home, target.destination(ready.copy(
            runtimes = ready.runtimes + ("duplicate" to current.copy(runtimeId = "duplicate")))))
    }

    @Test fun `pairing replacement rejects old target and timeout settles only once`() {
        val target = NotificationOpenTarget.create(pairing, "session")!!
        val queue = NotificationOpenQueue()
        val token = queue.enqueue(target)
        assertEquals(NotificationOpenDestination.Invalid,
            queue.resolve(token, pairing.copy(deviceId = "replacement"), RemoteState()))
        val timeoutToken = queue.enqueue(target)
        assertNull(queue.resolve(timeoutToken, pairing, RemoteState()))
        assertEquals(NotificationOpenDestination.Home, queue.resolve(timeoutToken, pairing, RemoteState(), expired = true))
        val live = RuntimeSummary("runtime", "Agent", "/repo", "running", sessionId = "session")
        assertNull(queue.resolve(timeoutToken, pairing, RemoteState(connection = RelayConnection.ONLINE,
            e2eReady = true, homeDirectoryReceived = true, runtimes = mapOf(live.runtimeId to live))))
        val cancelled = queue.enqueue(target)
        queue.cancel()
        assertNull(queue.resolve(cancelled, pairing, RemoteState(), expired = true))
    }

    @Test fun `queue replacement and cancel prevent stale navigation`() {
        val first = NotificationOpenTarget.create(pairing, "first")!!
        val second = NotificationOpenTarget.create(pairing, "second")!!
        val queue = NotificationOpenQueue()
        val old = queue.enqueue(first)
        val current = queue.enqueue(second)
        val ready = RemoteState(connection = RelayConnection.ONLINE, e2eReady = true, homeDirectoryReceived = true,
            sessions = mapOf("second" to SessionCatalogEntry("second", hasHistoryCache = true)))
        assertNull(queue.resolve(old, pairing, ready))
        assertEquals(NotificationOpenDestination.History("second"), queue.resolve(current, pairing, ready))
        queue.enqueue(first)
        queue.cancel()
        assertNull(queue.resolve(current, pairing, ready))
    }
}
