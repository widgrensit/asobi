import { AsobiClient } from "./client.js";
import { AsobiWebSocket } from "./websocket.js";
import { AuthApi } from "./auth.js";
import { PlayersApi } from "./players.js";
import { MatchesApi } from "./matches.js";
import { MatchmakerApi } from "./matchmaker.js";
import { LeaderboardsApi } from "./leaderboards.js";
import { EconomyApi } from "./economy.js";
import { InventoryApi } from "./inventory.js";
import { SocialApi } from "./social.js";
import { ChatApi } from "./chat.js";
import { TournamentsApi } from "./tournaments.js";
import { NotificationsApi } from "./notifications.js";
import { StorageApi } from "./storage.js";
import { VotesApi } from "./votes.js";
import type { AsobiClientOptions, AsobiWebSocketOptions } from "./types.js";

export class Asobi {
  readonly client: AsobiClient;
  readonly auth: AuthApi;
  readonly players: PlayersApi;
  readonly matches: MatchesApi;
  readonly matchmaker: MatchmakerApi;
  readonly leaderboards: LeaderboardsApi;
  readonly economy: EconomyApi;
  readonly inventory: InventoryApi;
  readonly social: SocialApi;
  readonly chat: ChatApi;
  readonly tournaments: TournamentsApi;
  readonly notifications: NotificationsApi;
  readonly storage: StorageApi;
  readonly votes: VotesApi;

  constructor(options: AsobiClientOptions) {
    this.client = new AsobiClient(options);
    this.auth = new AuthApi(this.client);
    this.players = new PlayersApi(this.client);
    this.matches = new MatchesApi(this.client);
    this.matchmaker = new MatchmakerApi(this.client);
    this.leaderboards = new LeaderboardsApi(this.client);
    this.economy = new EconomyApi(this.client);
    this.inventory = new InventoryApi(this.client);
    this.social = new SocialApi(this.client);
    this.chat = new ChatApi(this.client);
    this.tournaments = new TournamentsApi(this.client);
    this.notifications = new NotificationsApi(this.client);
    this.storage = new StorageApi(this.client);
    this.votes = new VotesApi(this.client);
  }

  websocket(options?: Partial<AsobiWebSocketOptions>): AsobiWebSocket {
    const token = this.client.getToken();
    if (!token && !options?.token) {
      throw new Error("No token available. Login first or provide a token.");
    }
    const baseUrl = this.client.baseUrl.replace(/^http/, "ws");
    return new AsobiWebSocket({
      url: options?.url ?? `${baseUrl}/ws`,
      token: options?.token ?? token!,
      ...options,
    });
  }
}

export { AsobiClient, AsobiError } from "./client.js";
export { AsobiWebSocket } from "./websocket.js";
export { AuthApi } from "./auth.js";
export { PlayersApi } from "./players.js";
export { MatchesApi } from "./matches.js";
export { MatchmakerApi } from "./matchmaker.js";
export { LeaderboardsApi } from "./leaderboards.js";
export { EconomyApi } from "./economy.js";
export { InventoryApi } from "./inventory.js";
export { SocialApi } from "./social.js";
export { ChatApi } from "./chat.js";
export { TournamentsApi } from "./tournaments.js";
export { NotificationsApi } from "./notifications.js";
export { StorageApi } from "./storage.js";
export { VotesApi } from "./votes.js";
export type * from "./types.js";
