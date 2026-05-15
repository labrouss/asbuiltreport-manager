// Simple cron scheduler — stores schedules in /etc/asbuiltreport/schedules.json
// Runs inside the app container, fires reports via the same internal logic

const fs   = require('fs');
const path = require('path');

const SCHEDULES_FILE = '/etc/asbuiltreport/schedules.json';

function loadSchedules() {
  try {
    if (fs.existsSync(SCHEDULES_FILE)) {
      return JSON.parse(fs.readFileSync(SCHEDULES_FILE, 'utf8'));
    }
  } catch (_) {}
  return [];
}

function saveSchedules(schedules) {
  const dir = path.dirname(SCHEDULES_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(SCHEDULES_FILE, JSON.stringify(schedules, null, 2));
}

// Parse a simple cron-like schedule into next run Date
// Supports: 'hourly', 'daily HH:MM', 'weekly DOW HH:MM', 'monthly DD HH:MM'
function nextRun(schedule) {
  const now = new Date();
  const next = new Date(now);

  if (schedule.frequency === 'hourly') {
    next.setMinutes(schedule.minute || 0, 0, 0);
    if (next <= now) next.setHours(next.getHours() + 1);
    return next;
  }

  if (schedule.frequency === 'daily') {
    const [h, m] = (schedule.time || '06:00').split(':').map(Number);
    next.setHours(h, m, 0, 0);
    if (next <= now) next.setDate(next.getDate() + 1);
    return next;
  }

  if (schedule.frequency === 'weekly') {
    const [h, m] = (schedule.time || '06:00').split(':').map(Number);
    const targetDay = schedule.dayOfWeek ?? 1; // 0=Sun
    next.setHours(h, m, 0, 0);
    const daysUntil = (targetDay - now.getDay() + 7) % 7 || 7;
    next.setDate(next.getDate() + (next <= now ? daysUntil : daysUntil === 7 ? 0 : daysUntil));
    if (next <= now) next.setDate(next.getDate() + 7);
    return next;
  }

  if (schedule.frequency === 'monthly') {
    const [h, m] = (schedule.time || '06:00').split(':').map(Number);
    const day = schedule.dayOfMonth || 1;
    next.setDate(day);
    next.setHours(h, m, 0, 0);
    if (next <= now) next.setMonth(next.getMonth() + 1);
    return next;
  }

  return null;
}

function startScheduler(runReportFn, broadcast) {
  console.log('[Scheduler] Starting...');

  setInterval(() => {
    const schedules = loadSchedules();
    const now = new Date();
    let changed = false;

    schedules.forEach((s) => {
      if (!s.enabled) return;
      const next = new Date(s.nextRun);
      if (now >= next) {
        console.log(`[Scheduler] Firing scheduled report: ${s.id} (${s.moduleId} → ${s.target})`);
        broadcast('schedule:fired', { scheduleId: s.id, moduleId: s.moduleId, target: s.target });
        runReportFn({
          moduleId:    s.moduleId,
          target:      s.target,
          credentials: s.credentials,
          options:     s.options || {},
        });
        s.lastRun  = now.toISOString();
        s.nextRun  = nextRun(s)?.toISOString() || null;
        changed = true;
      }
    });

    if (changed) saveSchedules(schedules);
  }, 30_000); // check every 30 seconds
}

module.exports = { loadSchedules, saveSchedules, nextRun, startScheduler };
