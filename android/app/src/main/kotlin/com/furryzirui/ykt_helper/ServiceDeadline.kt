package com.furryzirui.ykt_helper

/** Absolute expiry survives process recovery; monotonic expiry prevents a wall-clock rollback extending it. */
internal data class ServiceDeadline(
    val epochMs: Long,
    val elapsedMs: Long,
    val bootCount: Int
) {
    fun remaining(nowEpochMs: Long, nowElapsedMs: Long, currentBootCount: Int): Long {
        val wallRemaining = (epochMs - nowEpochMs).coerceAtLeast(0)
        return if (bootCount >= 0 && bootCount == currentBootCount) {
            minOf(wallRemaining, (elapsedMs - nowElapsedMs).coerceAtLeast(0))
        } else wallRemaining
    }

    companion object {
        fun configure(
            previous: ServiceDeadline?,
            epochMs: Long,
            nowEpochMs: Long,
            nowElapsedMs: Long,
            bootCount: Int
        ): ServiceDeadline {
            if (previous?.epochMs == epochMs && previous.bootCount == bootCount && bootCount >= 0) {
                return previous
            }
            val remaining = (epochMs - nowEpochMs).coerceAtLeast(0)
            val elapsedDeadline = if (remaining > Long.MAX_VALUE - nowElapsedMs) {
                Long.MAX_VALUE
            } else nowElapsedMs + remaining
            return ServiceDeadline(epochMs, elapsedDeadline, bootCount)
        }
    }
}

internal object ServiceExitPolicy {
    fun canExit(windowVisible: Boolean, foregroundActive: Boolean,
        processImportance: Int, visibleImportance: Int, foregroundServiceImportance: Int): Boolean =
        !windowVisible && !foregroundActive &&
            (processImportance == foregroundServiceImportance || processImportance > visibleImportance)
}

/** Distinguishes a real service restart from a repeated enable/configure call. */
internal object ServiceStartPolicy {
    enum class Decision { DENIED, CONTINUE, NEW_SESSION }

    fun restorationAllowed(enabled: Boolean, eligible: Boolean, suspended: Boolean,
        backgroundAllowed: Boolean): Boolean = enabled && eligible && !suspended && backgroundAllowed

    fun decide(running: Boolean, restoring: Boolean, restoreAllowed: Boolean,
        backgroundAllowed: Boolean): Decision = when {
        !backgroundAllowed || restoring && !restoreAllowed -> Decision.DENIED
        running -> Decision.CONTINUE
        else -> Decision.NEW_SESSION
    }
}
