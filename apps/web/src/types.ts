export type MeetingStatus = "idle" | "capturing" | "finalizing" | "analyzing" | "completed" | "interrupted" | "failed" | "partially_completed";
export type CaptureState = "idle" | "starting" | "capturing" | "stopping" | "failed";
export type AnalysisStatus = "pending" | "running" | "completed" | "failed";
export type ScreenRelation = "visible_during_speech" | "previously_visible" | "explicitly_referenced";

export interface CaptureStatus {
  status: CaptureState;
  meetingId?: string | null;
  videoFrames: number;
  systemAudioRms: number;
  microphoneRms: number;
  error?: string | null;
}
export interface Meeting {
  id: string;
  title: string | null;
  startedAt: string;
  endedAt?: string | null;
  status: MeetingStatus;
}
export interface ScreenRef {
  screenId: string;
  relation: ScreenRelation;
  overlapMs?: number | null;
  confidence?: number | null;
}
export interface TranscriptEvent {
  id: string;
  revision: number;
  startedAtMs: number;
  endedAtMs?: number;
  speaker: "self" | "remote" | "unknown";
  text: string;
  source: "microphone" | "system_audio" | "imported";
  isFinal: boolean;
  screenRefs: ScreenRef[];
}
export interface ScreenEvent {
  id: string;
  startedAtMs: number;
  endedAtMs?: number;
  imageUrl: string;
  ocr?: string | null;
  description?: string | null;
  analysisStatus: AnalysisStatus;
  error?: string;
}
export interface ActionItem { id?: string; text: string; owner?: string | null; dueDate?: string | null; }
export interface SummaryItem { text: string; evidenceIds: string[]; assignee?: string | null; dueAt?: string | null; }
export interface MeetingSummary {
  summary: string;
  decisions: SummaryItem[];
  actionItems: SummaryItem[];
  openQuestions: SummaryItem[];
  topics: string[];
}
export interface SummaryProgress {
  state: "not_started" | "queued" | "running" | "retrying" | "completed" | "failed";
  retryCount: number;
  error?: string | null;
  availableAt?: string | null;
}
export interface TranscriptionProgress extends SummaryProgress {
  hasSystemAudio: boolean;
  hasMicrophoneAudio: boolean;
  archivedBytes: number;
}
export type MeetingDetail = Meeting;
export interface MeetingPage { items: Meeting[]; nextCursor?: string | null; }
export interface Timeline { transcript: TranscriptEvent[]; screens: ScreenEvent[]; }
export interface Settings {
  sttProvider: "apple_speech";
  summaryProvider: "apple_foundation_models" | "codex";
  retentionDays: number;
  recoveryMode: boolean;
}
export type ServerEvent =
  | { type: "capture.started" | "capture.stopped"; payload: CaptureStatus }
  | { type: "transcript.partial" | "transcript.final"; meetingId: string; payload: TranscriptEvent }
  | { type: "screen.changed" | "screen.analyzed"; meetingId: string; payload: ScreenEvent }
  | { type: "summary.started" | "summary.completed"; meetingId: string; payload: MeetingSummary }
  | { type: "error"; meetingId?: string; payload: { message: string } };
