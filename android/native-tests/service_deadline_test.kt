package com.furryzirui.ykt_helper

fun main() {
    var checks = 0
    fun expect(expected: Long, actual: Long) {
        check(expected == actual) { "Expected $expected, got $actual" }
        checks++
    }
    val deadline = ServiceDeadline.configure(null, 1_600_000, 1_000_000, 20_000, 7)
    expect(600_000, deadline.remaining(1_000_000, 20_000, 7))
    expect(300_000, deadline.remaining(1_300_000, 320_000, 7))
    expect(0, deadline.remaining(1_600_000, 620_000, 7))
    expect(0, deadline.remaining(1_600_001, 620_001, 7))

    // Changing the wall clock backwards cannot extend this boot's countdown.
    expect(300_000, deadline.remaining(800_000, 320_000, 7))
    expect(0, deadline.remaining(800_000, 620_000, 7))
    // Moving the clock forwards expires at the absolute deadline immediately.
    expect(0, deadline.remaining(1_700_000, 30_000, 7))

    // Repeated configure/refresh, or a process restart, must retain the original
    // elapsed deadline. Reconstructing from the wall clock would extend it here.
    val restored = ServiceDeadline(deadline.epochMs, deadline.elapsedMs, deadline.bootCount)
    val repeated = ServiceDeadline.configure(restored, 1_600_000, 800_000, 320_000, 7)
    check(repeated == deadline)
    checks++
    expect(300_000, repeated.remaining(800_000, 320_000, 7))
    val repeatedExpired = ServiceDeadline.configure(restored, 1_600_000, 800_000, 620_000, 7)
    expect(0, repeatedExpired.remaining(800_000, 620_000, 7))

    // A new boot has a new elapsedRealtime origin; only the absolute deadline
    // applies until configure records the new boot's monotonic deadline.
    expect(200_000, restored.remaining(1_400_000, 5_000, 8))
    expect(0, restored.remaining(1_600_001, 5_000, 8))
    val rebooted = ServiceDeadline.configure(restored, 1_600_000, 1_400_000, 5_000, 8)
    expect(200_000, rebooted.remaining(1_400_000, 5_000, 8))
    expect(100_000, rebooted.remaining(1_000_000, 105_000, 8))

    // Explicitly choosing a new deadline starts a new countdown.
    val reselected = ServiceDeadline.configure(deadline, 2_200_000, 1_600_000, 620_000, 7)
    expect(600_000, reselected.remaining(1_600_000, 620_000, 7))
    val past = ServiceDeadline.configure(null, 1_000_000, 1_100_000, 20_000, 7)
    expect(0, past.remaining(1_100_000, 20_000, 7))
    // Unavailable boot count must never compare elapsed clocks across reboots.
    expect(200_000, ServiceDeadline(1_600_000, 10, -1).remaining(1_400_000, 100_000, -1))
    val large = ServiceDeadline.configure(null, Long.MAX_VALUE, 1, 100, 7)
    expect(Long.MAX_VALUE, large.elapsedMs)
    // Foreground/inactive-visible windows and system-visible process state all
    // prevent a timer or an explicit Dart exit request from killing the app.
    check(!ServiceExitPolicy.canExit(true, true, 100, 200, 125)); checks++
    check(!ServiceExitPolicy.canExit(true, false, 125, 200, 125)); checks++
    check(!ServiceExitPolicy.canExit(false, true, 300, 200, 125)); checks++
    check(!ServiceExitPolicy.canExit(false, false, 100, 200, 125)); checks++
    check(!ServiceExitPolicy.canExit(false, false, 200, 200, 125)); checks++
    check(ServiceExitPolicy.canExit(false, false, 125, 200, 125)); checks++
    check(ServiceExitPolicy.canExit(false, false, 230, 200, 125)); checks++
    check(ServiceExitPolicy.canExit(false, false, 400, 200, 125)); checks++
    fun start(expected: ServiceStartPolicy.Decision, running: Boolean, restoring: Boolean,
        enabled: Boolean = true, eligible: Boolean = true, suspended: Boolean = false,
        allowed: Boolean = true) {
        val restoreAllowed = ServiceStartPolicy.restorationAllowed(enabled, eligible, suspended, allowed)
        check(ServiceStartPolicy.decide(running, restoring, restoreAllowed, allowed) == expected)
        checks++
    }
    // Repeated enable, Activity reattachment and receiver messages cannot clear
    // a user-selected countdown on a service that is actually still running.
    start(ServiceStartPolicy.Decision.CONTINUE, running = true, restoring = false)
    start(ServiceStartPolicy.Decision.CONTINUE, running = true, restoring = true)
    // New manual, boot and killed-service recovery sessions begin unlimited.
    start(ServiceStartPolicy.Decision.NEW_SESSION, running = false, restoring = false)
    start(ServiceStartPolicy.Decision.NEW_SESSION, running = false, restoring = true)
    // Manual service start does not require enabling application auto-start.
    start(ServiceStartPolicy.Decision.NEW_SESSION, running = false, restoring = false,
        enabled = false, eligible = false)
    // An expired timer/manual stop sets suspended. A boot or sticky recovery
    // must not clear that state in order to manufacture a new unlimited session.
    start(ServiceStartPolicy.Decision.DENIED, running = false, restoring = true, suspended = true)
    start(ServiceStartPolicy.Decision.DENIED, running = true, restoring = true, suspended = true)
    start(ServiceStartPolicy.Decision.DENIED, running = false, restoring = true, enabled = false)
    start(ServiceStartPolicy.Decision.DENIED, running = false, restoring = true, eligible = false)
    // Neither manual requests nor repeated requests bypass revoked OS permission.
    start(ServiceStartPolicy.Decision.DENIED, running = false, restoring = false, allowed = false)
    start(ServiceStartPolicy.Decision.DENIED, running = true, restoring = false, allowed = false)
    start(ServiceStartPolicy.Decision.DENIED, running = false, restoring = true, allowed = false)
    println("Android service deadline: $checks checks passed")
}
