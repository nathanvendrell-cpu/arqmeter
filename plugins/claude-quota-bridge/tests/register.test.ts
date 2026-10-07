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
  test('absent quota and context-only events do not become 100 percent', async () => {
    expect(quotaInput(measure([]), now)).toBeNull()
    expect(quotaInput(measure([window()], ['context']), now)).toBeNull()
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
  test('no process for unknown quota or context-only changes', async ($, on) => {
    mock.clock(on, { now })
    on('session.measure', ($, e) => ({ changed: e.changed }))
    await $.session.measure(measure([]) as any)
    await $.session.measure(measure([window()], ['context']) as any)
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
})
