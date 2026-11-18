package com.orbising.orbis

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** Native goal controls stay outside the transcript and never change the message composer draft. */
@Composable
internal fun SessionGoalPanel(
    state: RemoteState,
    runtimeId: String,
    onCommand: (SessionGoalCommand) -> String?,
    onConsumeResult: (String) -> Unit,
) {
    val runtime = state.runtimes[runtimeId] ?: return
    if (!runtime.goalSupported) return
    val view = state.sessionGoal(runtimeId)
    val goal = view?.goal
    var open by remember(state.hostId, runtimeId, runtime.sessionId) { mutableStateOf(false) }
    var pending by remember(state.hostId, runtimeId, runtime.sessionId) { mutableStateOf<String?>(null) }
    var action by remember(state.hostId, runtimeId, runtime.sessionId) { mutableStateOf<SessionGoalCommand>(SessionGoalCommand.Read) }
    var error by remember(state.hostId, runtimeId, runtime.sessionId) { mutableStateOf<String?>(null) }
    var notice by remember(state.hostId, runtimeId, runtime.sessionId) { mutableStateOf<String?>(null) }
    var readConfirmed by remember(state.hostId, runtimeId, runtime.sessionId) { mutableStateOf(false) }
    var objective by remember(state.hostId, runtimeId, runtime.sessionId) { mutableStateOf("") }
    var budget by remember(state.hostId, runtimeId, runtime.sessionId) { mutableStateOf("") }
    var edited by remember(state.hostId, runtimeId, runtime.sessionId) { mutableStateOf(false) }

    fun submit(command: SessionGoalCommand) {
        if (pending != null) return
        error = null
        notice = null
        action = command
        pending = onCommand(command)
        if (pending == null) error = L10n.tr("目标操作未发送，请连接电脑后重试")
    }
    LaunchedEffect(open, state.e2eReady) {
        if (open && state.e2eReady) {
            readConfirmed = false
            submit(SessionGoalCommand.Read)
        }
    }
    LaunchedEffect(goal?.objective, goal?.tokenBudget, edited) {
        if (!edited) {
            objective = goal?.objective.orEmpty()
            budget = goal?.tokenBudget?.toString().orEmpty()
        }
    }
    LaunchedEffect(pending, state.commandResults) {
        val id = pending ?: return@LaunchedEffect
        val result = state.commandResults[id] ?: return@LaunchedEffect
        if (result.status == "pending") return@LaunchedEffect
        pending = null
        onConsumeResult(id)
        if (result.ok && result.status == "success") {
            if (action == SessionGoalCommand.Read) readConfirmed = true
            else {
                if (action is SessionGoalCommand.Edit) edited = false
                notice = L10n.tr("目标已更新")
            }
        } else {
            readConfirmed = false
            error = result.error ?: L10n.tr("目标操作未确认，请重新读取")
        }
    }

    NeumorphSurface(
        Modifier.fillMaxWidth().padding(horizontal = RemoteUi.PagePadding).testTag("session-goal-entry"),
        flat = true, onClick = { open = true },
    ) {
        Row(Modifier.fillMaxWidth().heightIn(min = RemoteUi.TouchTarget).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(L10n.tr("目标"), style = MaterialTheme.typography.labelMedium)
            Text(goal?.objective ?: L10n.tr("查看或设置目标"), Modifier.weight(1f),
                style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            goal?.let { Text(it.statusTitle, style = MaterialTheme.typography.labelSmall) }
        }
    }
    if (!open) return
    OrbisChoiceSheet(L10n.tr("会话目标"), { open = false }) {
        val canEdit = state.e2eReady && pending == null && readConfirmed && view != null
        val parsedBudget = budget.trim().takeIf(String::isNotEmpty)?.toLongOrNull()
        val validBudget = budget.isBlank() || parsedBudget != null && parsedBudget > 0
        Column(Modifier.fillMaxWidth().testTag("session-goal-sheet"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (goal != null) {
                Text(goal.statusTitle, Modifier.testTag("session-goal-status"), style = MaterialTheme.typography.titleMedium)
                Text(if (goal.tokenBudget == null) L10n.tr("已用 {0} tokens · 未设预算", goal.tokensUsed)
                    else L10n.tr("已用 {0} / {1} tokens", goal.tokensUsed, goal.tokenBudget),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else if (view != null) Text(L10n.tr("尚未设置目标"))
            if (pending != null) Text(L10n.tr(if (action == SessionGoalCommand.Read) "正在读取目标…" else "正在更新目标…"))
            if (!state.e2eReady) Text(L10n.tr("连接电脑后可读取和修改目标"))
            error?.let { InlineFeedbackError(it) }
            notice?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
            NeumorphTextField(objective, { objective = it; edited = true },
                Modifier.fillMaxWidth().testTag("session-goal-objective"),
                label = { Text(L10n.tr("目标内容")) }, enabled = canEdit, minLines = 3, maxLines = 7)
            NeumorphTextField(budget, { budget = it; edited = true },
                Modifier.fillMaxWidth().testTag("session-goal-budget"),
                label = { Text(L10n.tr("Token 预算（留空不限）")) }, enabled = canEdit, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), isError = !validBudget,
                supportingText = if (validBudget) null else { { Text(L10n.tr("预算须为正整数")) } })
            NeumorphTextButton(L10n.tr("保存目标"), {
                submit(SessionGoalCommand.Edit(objective.trim(), parsedBudget))
            }, Modifier.fillMaxWidth().testTag("session-goal-save"),
                enabled = canEdit && objective.isNotBlank() && validBudget && (edited || goal == null),
                filled = true, dismissOnClick = false)
            if (goal?.status in setOf("active", "paused")) {
                val paused = goal?.status == "paused"
                NeumorphTextButton(L10n.tr(if (paused) "恢复目标" else "暂停目标"), {
                    submit(SessionGoalCommand.SetStatus(if (paused) "active" else "paused"))
                }, Modifier.fillMaxWidth().testTag("session-goal-toggle"), enabled = canEdit, dismissOnClick = false)
            }
            NeumorphTextButton(L10n.tr("重新读取"), {
                readConfirmed = false
                submit(SessionGoalCommand.Read)
            }, enabled = state.e2eReady && pending == null, dismissOnClick = false)
        }
    }
}
