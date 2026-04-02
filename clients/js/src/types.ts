// --- Auth ---

export interface RegisterParams {
  username: string;
  password: string;
  display_name?: string;
}

export interface LoginParams {
  username: string;
  password: string;
}

export interface AuthResponse {
  player_id: string;
  session_token: string;
  username: string;
}

export interface RefreshResponse {
  player_id: string;
  session_token: string;
}

export interface OAuthParams {
  provider: string;
  token: string;
}

export interface LinkProviderParams {
  provider: string;
  token: string;
}

export interface UnlinkProviderParams {
  provider: string;
}

// --- IAP ---

export interface IapReceiptParams {
  receipt: string;
  product_id?: string;
}

export interface IapResult {
  valid: boolean;
  product_id?: string;
  [key: string]: unknown;
}

// --- Players ---

export interface Player {
  id: string;
  username: string;
  display_name: string;
  [key: string]: unknown;
}

export interface UpdatePlayerParams {
  display_name?: string;
  [key: string]: unknown;
}

// --- Matches ---

export interface Match {
  id: string;
  mode: string;
  status: string;
  players: string[];
  [key: string]: unknown;
}

export interface MatchListParams {
  limit?: number;
  offset?: number;
  status?: string;
}

// --- Matchmaker ---

export interface MatchmakerAddParams {
  mode?: string;
  properties?: Record<string, unknown>;
  party?: string[];
}

export interface MatchmakerTicket {
  ticket_id: string;
  status: string;
  [key: string]: unknown;
}

// --- Leaderboards ---

export interface LeaderboardEntry {
  player_id: string;
  score: number;
  rank: number;
  [key: string]: unknown;
}

export interface LeaderboardTopParams {
  limit?: number;
  offset?: number;
}

export interface SubmitScoreParams {
  score: number;
  metadata?: Record<string, unknown>;
}

// --- Economy ---

export interface Wallet {
  currency: string;
  balance: number;
  [key: string]: unknown;
}

export interface WalletHistoryParams {
  limit?: number;
  offset?: number;
}

export interface Transaction {
  id: string;
  amount: number;
  currency: string;
  type: string;
  [key: string]: unknown;
}

export interface StoreItem {
  id: string;
  name: string;
  price: number;
  currency: string;
  [key: string]: unknown;
}

export interface PurchaseParams {
  item_id: string;
  quantity?: number;
}

export interface PurchaseResult {
  success: boolean;
  [key: string]: unknown;
}

// --- Inventory ---

export interface InventoryItem {
  id: string;
  item_id: string;
  quantity: number;
  [key: string]: unknown;
}

export interface ConsumeParams {
  item_id: string;
  quantity?: number;
}

// --- Social ---

export interface Friend {
  friend_id: string;
  status: string;
  [key: string]: unknown;
}

export interface AddFriendParams {
  player_id: string;
}

export interface UpdateFriendParams {
  status: string;
}

export interface Group {
  id: string;
  name: string;
  [key: string]: unknown;
}

export interface CreateGroupParams {
  name: string;
  [key: string]: unknown;
}

// --- Chat ---

export interface ChatMessage {
  id: string;
  channel_id: string;
  player_id: string;
  content: string;
  [key: string]: unknown;
}

export interface ChatHistoryParams {
  limit?: number;
  before?: string;
}

// --- Tournaments ---

export interface Tournament {
  id: string;
  name: string;
  status: string;
  [key: string]: unknown;
}

export interface TournamentListParams {
  limit?: number;
  offset?: number;
  status?: string;
}

// --- Notifications ---

export interface Notification {
  id: string;
  type: string;
  read: boolean;
  [key: string]: unknown;
}

export interface NotificationListParams {
  limit?: number;
  offset?: number;
}

// --- Storage ---

export interface SaveData {
  slot: string;
  data: Record<string, unknown>;
  [key: string]: unknown;
}

export interface StorageItem {
  key: string;
  value: Record<string, unknown>;
  [key: string]: unknown;
}

export interface StorageListParams {
  limit?: number;
  offset?: number;
}

// --- Votes ---

export interface Vote {
  id: string;
  match_id: string;
  options: VoteOption[];
  [key: string]: unknown;
}

export interface VoteOption {
  id: string;
  label: string;
  [key: string]: unknown;
}

// --- WebSocket ---

export interface WsMessage {
  type: string;
  payload: Record<string, unknown>;
  cid?: string;
}

export type WsEventType =
  | "session.connected"
  | "session.heartbeat"
  | "match.state"
  | "match.joined"
  | "match.left"
  | "match.input"
  | "matchmaker.queued"
  | "matchmaker.removed"
  | "chat.message"
  | "chat.joined"
  | "chat.left"
  | "presence.updated"
  | "notification.new"
  | "vote.cast_ok"
  | "vote.veto_ok"
  | "error";

export interface AsobiClientOptions {
  baseUrl: string;
  token?: string;
}

export interface AsobiWebSocketOptions {
  url: string;
  token: string;
  reconnect?: boolean;
  reconnectInterval?: number;
  maxReconnectAttempts?: number;
  heartbeatInterval?: number;
}

export interface ApiError {
  status: number;
  error?: string;
  errors?: Record<string, string[]>;
}
