export interface EntityTypeMeta {
  name: string;
  label: string;
  grouped: boolean;
  id_field: string;
  core: boolean;
}

export interface Meta {
  dc_profile: string;
  branch: string;
  gitlab_web_url: string;
  auth_mode: string;
  actor: string;
  entity_types: EntityTypeMeta[];
}

export interface FragmentItem {
  id: string | null;
  name: string | null;
}

export interface FragmentInfo {
  path: string;
  file: string;
  group: string | null;
  disabled: boolean;
  parse_error: string | null;
  items: FragmentItem[];
}

export interface EntityListResponse {
  entity_type: string;
  files: FragmentInfo[];
  groups: string[];
  head_sha: string;
}

export interface FileResponse {
  path: string;
  content: string;
  blob_sha: string | null;
  head_sha: string;
  disabled: boolean;
}

export interface Finding {
  level: "error" | "warning" | "info";
  message: string;
  rule: string;
  line: number | null;
}

export interface SaveResult {
  commit: string;
  commit_short: string;
  commit_url: string;
  message: string;
  next: string;
  findings?: Finding[];
}

export interface CommitInfo {
  sha: string;
  short: string;
  author: string;
  email: string;
  date: string;
  subject: string;
  web_url: string;
}

export interface GitsyncStatus {
  available: boolean;
  last_start: { ts: string; profile: string; commit: string; msg: string } | null;
  last_done: { ts: string; commit: string } | null;
  recent_warnings: string[];
}

export interface HubPeer {
  id: string;
  dc: string;
  label: string;
}

export interface HubInfo {
  current: string | null;
  hub_port: number;
  peers: HubPeer[];
}

export interface StatusResponse {
  dc_profile: string;
  workspace_head: string | null;
  gitsync: GitsyncStatus;
  apisix: { available: boolean; last_reloaded: { ts: string; file: string } | null };
  hint: string;
}
