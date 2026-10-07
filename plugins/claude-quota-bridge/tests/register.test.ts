import { describe, expect, mock, test, tier } from 'claude-code/testing'
import { quotaInput } from '../hooks/register.js'

tier('user')

const now = Date.parse('2026-10-07T10:00:00Z')
const reset = '2026-10-07T14:00:00Z'
const measure = (rateLimits: unknown[], changed = ['rateLimits']) => ({
  context: { window: 200000 }, rateLimits, changed,
})
const window = (kind = 'five_hour', percentUsed = 23.5, resetsAt = reset) => ({
  kind, percentUsed, resetsAt,
})

describe('register', () => {
  test('normalizes both official windows, never context or spend limits', async () => {
    const value = quotaInput(measure([window(), window('seven_day', 40), window('spend_limit')]), now)
    expect(value).toEqual({ rate_limits: {
      five_hour: { used_percentage: 23.5, resets_at: Date.parse(reset) / 1000 },
      seven_day: { used_percentage: 40, resets_at: Date.parse(reset) / 1000 },
    } })
  })
  test('absent quota never becomes 100 percent; a changed unit is not a field filter', async () => {
    expect(quotaInput(measure([]), now)).toBeNull()
    expect(quotaInput(measure([], ['context']), now)).toBeNull()
    expect(quotaInput(measure([window()], ['context']), now)?.rate_limits.five_hour.used_percentage).toBe(23.5)
    expect(quotaInput(measure([window()], []), now)).toBeNull()
    expect(quotaInput({ context: { percent: 42 }, changed: ['rateLimits'] }, now)).toBeNull()
  })
  test('rejects invalid, expired, duplicated or unsupported windows independently', async () => {
    for (const value of [window('five_hour', -1), window('five_hour', 101),
      window('five_hour', NaN), window('five_hour', Infinity),
      window('five_hour', 1, 'bad'), window('five_hour', 1, '2026-10-06T00:00:00Z')]) {
      expect(quotaInput(measure([value]), now)).toBeNull()
    }
    expect(quotaInput(measure([window(), window()]), now)).toBeNull()
    expect(quotaInput(measure([window('spend_limit')]), now)).toBeNull()
    expect(quotaInput(measure([window(), window('seven_day', 101)]), now)).toEqual({
      rate_limits: { five_hour: { used_percentage: 23.5, resets_at: Date.parse(reset) / 1000 } },
    })
  })
  test('delivers locally, deduplicates, and preserves event and result', async ($, on) => {
    mock.clock(on, { now })
    mock.env(on, { HOME: '/test-user' })
    const calls: any[] = []
    const events: any[] = []
    let receipt: any
    on('store.set', ($, e) => { receipt = e.value; return { value: undefined } })
    on('session.measure', ($, e) => { events.push(e); return { changed: e.changed } })
    on('process.run', ($, e) => {
      calls.push(e)
      return { value: { exitCode: 0, stdout: calls.length === 1 ? 'true\n' : '', stderr: '' } }
    })
    const event = measure([window(), window('seven_day', 40)])
    const [result] = await Promise.all([
      $.session.measure(event as any), $.session.measure(event as any),
    ])
    expect(result).toEqual({ changed: ['rateLimits'] })
    expect(events).toEqual([event, event])
    expect(calls.length).toBe(2)
    expect(calls[1].argv).toEqual(['/test-user/Applications/Arqmeter.app/Contents/MacOS/Arqmeter', '--capture-claude-status'])
    const payload = JSON.parse(calls[1].init.stdin)
    expect(Object.keys(payload).sort()).toEqual(['rate_limits', 'session_id'])
    expect(receipt.source).toContain('session.measure')
    expect(receipt.serverObservedAt).toBeNull()
  })
  test('no process for measurements that contain no quota', async ($, on) => {
    mock.clock(on, { now })
    on('session.measure', ($, e) => ({ changed: e.changed }))
    await $.session.measure(measure([]) as any)
    await $.session.measure(measure([], ['context']) as any)
    // Any unexpected process, model, filesystem or auth call fails the engine test.
  })
  test('a rollback without the capability is not executed', async ($, on) => {
    mock.clock(on, { now })
    mock.env(on, { HOME: '/test-user' })
    let count = 0
    on('session.measure', ($, e) => ({ changed: e.changed }))
    on('process.run', () => { count++; return { value: { exitCode: 1, stdout: '', stderr: '' } } })
    await $.session.measure(measure([window()]) as any)
    expect(count).toBe(1)
  })
  test('delivery errors do not interrupt Claude and remain retryable', async ($, on) => {
    mock.clock(on, { now })
    mock.env(on, { HOME: '/test-user' })
    let count = 0
    on('session.measure', ($, e) => ({ changed: e.changed }))
    on('process.run', () => { count++; throw new Error('offline receiver') })
    const event = measure([window()])
    expect(await $.session.measure(event as any)).toEqual({ changed: ['rateLimits'] })
    await $.session.measure(event as any)
    expect(count).toBe(2)
  })
  test('unchanged percentages refresh only after a new engine event, with bounded burst coalescing', async ($, on) => {
    let clock = now
    on('clock.now', () => ({ value: clock }))
    mock.env(on, { HOME: '/test-user' })
    let calls = 0
    let receipts: any[] = []
    on('store.set', ($, e) => { receipts.push(e.value); return { value: undefined } })
    on('session.measure', ($, e) => ({ changed: e.changed }))
    on('process.run', ($, e) => {
      calls++
      return { value: { exitCode: 0, stdout: e.argv[0] === '/usr/libexec/PlistBuddy' ? 'true\n' : '', stderr: '' } }
    })
    const event = measure([window(), window('seven_day', 40)], ['context'])
    await $.session.measure(event as any)
    clock += 59_999
    await $.session.measure(event as any)
    expect(calls).toBe(2)
    expect(receipts.length).toBe(1)
    clock += 1
    await $.session.measure(event as any)
    expect(calls).toBe(4)
    expect(receipts.length).toBe(2)
    expect(receipts[1].receivedAt).toBe(new Date(clock).toISOString())
    expect(receipts[1].serverObservedAt).toBeNull()
    clock += 180_000 // A clock advancing alone must not write a receipt.
    expect(receipts.length).toBe(2)
  })
  test('changed quota is delivered immediately even inside the coalescing interval', async ($, on) => {
    mock.clock(on, { now })
    mock.env(on, { HOME: '/test-user' })
    let calls = 0
    on('session.measure', ($, e) => ({ changed: e.changed }))
    on('process.run', ($, e) => {
      calls++
      return { value: { exitCode: 0, stdout: e.argv[0] === '/usr/libexec/PlistBuddy' ? 'true\n' : '', stderr: '' } }
    })
    await $.session.measure(measure([window()]) as any)
    await $.session.measure(measure([window('five_hour', 24)], ['cost']) as any)
    expect(calls).toBe(4)
  })
  test('exhausted session is a real 100 percent used, not an absent quota or a weekly substitute', () => {
    expect(quotaInput(measure([window('five_hour', 100), window('seven_day', 81)]), now)).toEqual({ rate_limits: {
      five_hour: { used_percentage: 100, resets_at: Date.parse(reset) / 1000 },
      seven_day: { used_percentage: 81, resets_at: Date.parse(reset) / 1000 },
    } })
    expect(quotaInput(measure([window('seven_day', 81)]), now)?.rate_limits.five_hour).toBeUndefined()
  })
})
