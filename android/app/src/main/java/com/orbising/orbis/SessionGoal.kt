package com.orbising.orbis

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable
data class SessionGoal(
    val threadId: String,
    val objective: String,
    val status: String,
    val tokenBudget: Long?,
    val tokensUsed: Long,
    val timeUsedSeconds: Double,
    val createdAt: Double,
    val updatedAt: Double,
) {
    val statusTitle: String get() = L10n.tr(when (status) {
        "active" -> "进行中"
        "paused" -> "已暂停"
        "blocked" -> "受阻"
        "usageLimited" -> "已达用量限制"
        "budgetLimited" -> "已达预算"
        "complete" -> "已完成"
        else -> "未确认"
    })
}

/** A null goal is confirmed absence; a missing view means the goal has not been read. */
data class SessionGoalView(val sessionId: String, val goal: SessionGoal?)

sealed interface SessionGoalCommand {
    data object Read : SessionGoalCommand
    data class Edit(val objective: String, val tokenBudget: Long?) : SessionGoalCommand
    data class SetStatus(val status: String) : SessionGoalCommand

    fun payload(): JsonObject = buildJsonObject {
        put("type", if (this@SessionGoalCommand == Read) "session.goal.read" else "session.goal.set")
        when (val command = this@SessionGoalCommand) {
            Read -> Unit
            is Edit -> {
                put("objective", command.objective)
                put("tokenBudget", command.tokenBudget?.let(::JsonPrimitive) ?: JsonNull)
            }
            is SetStatus -> put("status", command.status)
        }
    }
}

internal fun RemoteState.sessionGoal(runtimeId: String): SessionGoalView? = sessionGoals[runtimeId]
    ?.takeIf { it.sessionId == runtimes[runtimeId]?.sessionId }

internal fun RemoteState.withSessionGoal(runtimeId: String, event: JsonObject, json: Json): RemoteState {
    val sessionId = runtimes[runtimeId]?.sessionId ?: return this
    val value = event["goal"] ?: return this
    val goal = if (value is JsonNull) null else runCatching {
        json.decodeFromJsonElement<SessionGoal>(value).also {
            require(it.status in setOf("active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"))
        }
    }.getOrElse { return conversationFailure(runtimeId, L10n.tr("目标信息读取失败，请重新读取")) }
    if (goal != null && sessionId != goal.threadId && sessionId != "codex-desktop:${goal.threadId}") return this
    return copy(sessionGoals = sessionGoals + (runtimeId to SessionGoalView(sessionId, goal)))
}
