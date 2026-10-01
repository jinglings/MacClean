const formatters = new Map();

/** `YYYY-MM-DD` of `date` in `timeZone`. */
export function dayKey(date, timeZone) {
  let fmt = formatters.get(timeZone);
  if (!fmt) {
    fmt = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' });
    formatters.set(timeZone, fmt);
  }
  return fmt.format(date instanceof Date ? date : new Date(date));
}

/** The last `count` day keys ending today, oldest first. */
export function lastDays(count, timeZone, now = new Date()) {
  const days = [];
  for (let i = count - 1; i >= 0; i--) days.push(dayKey(new Date(now.getTime() - i * 86400000), timeZone));
  return [...new Set(days)];
}

export function rfc822(iso) {
  return new Date(iso).toUTCString().replace('GMT', '+0000');
}
