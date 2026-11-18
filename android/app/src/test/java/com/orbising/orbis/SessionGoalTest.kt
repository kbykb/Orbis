package com.orbising.orbis

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SessionGoalTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val reducer = RelayReducer()
    private val runtime = RuntimeSummary("runtime", "Codex", "/fixture", "idle", "thread", goalSupported = true)
    private fun state() = RemoteState(selectedRuntimeId = "runtime", runtimes = mapOf("runtime" to runtime))
    private fun event(sequence: Int, status: String? = "active", runtimeId: String = "runtime") = buildJsonObject {
        put("type", "runtime.event"); put("runtimeId", runtimeId); put("sequence", sequence)
        put("event", buildJsonObject {
            put("type", "session.goal")
            put("goal", if (status == null) JsonNull else buildJsonObject {
                put("threadId", "thread"); put("objective", "Finish the fixture"); put("status", status)
                put("tokenBudget", 50000); put("tokensUsed", 42); put("timeUsedSeconds", 2.5)
                put("createdAt", 100.25); put("updatedAt", 200.75)
            })
        })
    }.toString()

    @Test fun `native goal updates pause resume and clear without adding chat messages`() {
        var next = reducer.reduce(state(), event(1))
        assertEquals("thread", next.sessionGoal("runtime")?.goal?.threadId)
        assertEquals("active", next.sessionGoal("runtime")?.goal?.status)
        assertEquals(200.75, next.sessionGoal("runtime")?.goal?.updatedAt)
        assertEquals(42L, next.sessionGoal("runtime")?.goal?.tokensUsed)
        next = reducer.reduce(next, event(2, "paused"))
        assertEquals("paused", next.sessionGoal("runtime")?.goal?.status)
        next = reducer.reduce(next, event(3, "active"))
        assertEquals("active", next.sessionGoal("runtime")?.goal?.status)
        assertEquals(next, reducer.reduce(next, event(2, "paused")))
        next = reducer.reduce(next, event(4, null))
        assertNotNull(next.sessionGoal("runtime"))
        assertNull(next.sessionGoal("runtime")?.goal)
        assertTrue(next.conversations["runtime"]?.messages.isNullOrEmpty())
        assertEquals("runtime", next.selectedRuntimeId)
    }

    @Test fun `goal views belong to the exact runtime session and unknown runtimes do not create one`() {
        val next = reducer.reduce(state(), event(1))
        val changed = next.copy(runtimes = mapOf("runtime" to runtime.copy(sessionId = "other")))
        assertNull(changed.sessionGoal("runtime"))
        assertTrue(reducer.reduce(changed, event(2)).sessionGoal("runtime") == null)
        val desktop = state().copy(runtimes = mapOf("runtime" to runtime.copy(sessionId = "codex-desktop:thread")))
        assertEquals("thread", reducer.reduce(desktop, event(1)).sessionGoal("runtime")?.goal?.threadId)
        val unrelated = reducer.reduce(state(), event(1, runtimeId = "unknown"))
        assertTrue(unrelated.sessionGoals.isEmpty())
    }

    @Test fun `read edit pause and resume use native command fields without overwriting each other`() {
        assertEquals(json.parseToJsonElement("""{"type":"session.goal.read"}"""), SessionGoalCommand.Read.payload())
        assertEquals(json.parseToJsonElement("""{"type":"session.goal.set","status":"paused"}"""),
            SessionGoalCommand.SetStatus("paused").payload())
        assertEquals(json.parseToJsonElement("""{"type":"session.goal.set","status":"active"}"""),
            SessionGoalCommand.SetStatus("active").payload())
        val edit = SessionGoalCommand.Edit("Updated objective", null).payload()
        assertEquals("Updated objective", edit["objective"]?.jsonPrimitive?.content)
        assertEquals(JsonNull, edit["tokenBudget"])
        assertFalse("status" in edit)
        assertEquals(75000L, SessionGoalCommand.Edit("Updated objective", 75000).payload()["tokenBudget"]?.jsonPrimitive?.longOrNull)
    }

    @Test fun `goal capability comes from authenticated identity and older hosts keep it hidden`() {
        assertFalse(json.decodeFromString<RuntimeSummary>("""{"runtimeId":"old","name":"Codex","cwd":"/fixture","status":"idle"}""").goalSupported)
        val identity = buildJsonObject {
            put("runtimeId", "runtime"); put("sessionId", "thread"); put("name", "Codex")
            put("cwd", "/fixture"); put("status", "idle"); put("goalSupported", true)
        }
        val domain = AgentStateDomainView("identity", "epoch", 1, "ready", "complete", 1, identity)
        val next = state().copy(runtimes = mapOf("runtime" to runtime.copy(goalSupported = false)))
            .applyAgentDomainProjection("runtime", "thread", mapOf("identity" to domain), json) { _, _, _ -> null }
        assertTrue(next.runtimes["runtime"]?.goalSupported == true)
        val disabled = next.applyAgentDomainProjection("runtime", "thread", mapOf("identity" to domain.copy(
            value = JsonObject(identity + ("goalSupported" to JsonPrimitive(false))))), json) { _, _, _ -> null }
        assertFalse(disabled.runtimes["runtime"]?.goalSupported == true)
    }
}
