// Wire semantics shared with GSDModel's documented Task/Recurrence/TimeTracking contract.
export const quadrant = (urgent, important) => urgent
  ? (important ? 'urgentImportant' : 'urgentNotImportant')
  : (important ? 'notUrgentImportant' : 'notUrgentNotImportant');

export function validDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(value) || !Number.isFinite(Date.parse(value)))
    throw Error('Use an ISO-8601 date with time and timezone');
  return new Date(value).toISOString();
}
export function nextRecurringTask(row, now, newId) {
  if (!['daily','weekly','monthly'].includes(row.recurrence)) return null;
  let due = '';
  if (row.due_date && Number.isFinite(Date.parse(row.due_date))) {
    const d = new Date(row.due_date);
    if (row.recurrence === 'monthly') {
      const day = d.getUTCDate();
      d.setUTCDate(1); d.setUTCMonth(d.getUTCMonth() + 1);
      const last = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth()+1,0)).getUTCDate();
      d.setUTCDate(Math.min(day,last));
    } else d.setUTCDate(d.getUTCDate() + (row.recurrence === 'daily' ? 1 : 7));
    due=d.toISOString();
  }
  const result = { ...row, task_id:newId(), completed:false, completed_at:'',
    due_date:due, client_created_at:now, client_updated_at:now, device_id:'chatgpt-cloud',
    notification_sent:false, last_notification_at:'', snoozed_until:'',
    time_spent:0,time_entries:[],saved_at:'',focus_date:'',focus_rank:0,
    subtasks:(row.subtasks||[]).map(s=>({id:newId(),title:s.title,completed:false})) };
  for(const k of ['id','collectionId','collectionName','created','updated','expand']) delete result[k];
  return result;
}
export function dependencyWouldCycle(rows, id, dependency) {
  const graph=new Map(rows.map(r=>[r.task_id,r.dependencies||[]]));
  const seen=new Set(),stack=[dependency];
  while(stack.length) {
    const next=stack.pop();
    if(next===id)return true;
    if(seen.has(next))continue;
    seen.add(next);stack.push(...(graph.get(next)||[]));
  }
  return false;
}
export const builtInViews = [
 ['today-focus',"Today's Focus",'target'], ['this-week','This Week','calendar'],
 ['overdue','Overdue Backlog','exclamationmark.triangle'], ['no-deadline','No Deadline','calendar.badge.minus'],
 ['recently-added','Recently Added','sparkles'], ['weeks-wins',"This Week's Wins",'checkmark.seal'],
 ['all-completed','All Completed','checkmark.circle'], ['recurring','Recurring Tasks','repeat'],
 ['ready-to-work','Ready to Work','bolt']
].map(([id,name,icon])=>({id,name,icon,isBuiltIn:true}));
