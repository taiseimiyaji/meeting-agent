import type { Meeting } from "./types";

export function meetingStartStamp(meeting: Meeting) {
  const start = new Date(meeting.startedAt);
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${start.getFullYear()}-${pad(start.getMonth() + 1)}-${pad(start.getDate())} ${pad(start.getHours())}:${pad(start.getMinutes())}`;
}

export function meetingName(meeting: Meeting) {
  return meeting.title?.trim() || `${meetingStartStamp(meeting)} ミーティング`;
}
