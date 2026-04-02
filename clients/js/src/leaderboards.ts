import { AsobiClient } from "./client.js";
import type { LeaderboardEntry, LeaderboardTopParams, SubmitScoreParams } from "./types.js";

const PREFIX = "/api/v1/leaderboards";

export class LeaderboardsApi {
  constructor(private client: AsobiClient) {}

  top(id: string, params?: LeaderboardTopParams): Promise<LeaderboardEntry[]> {
    return this.client.get<LeaderboardEntry[]>(`${PREFIX}/${id}`, params as Record<string, unknown>);
  }

  submit(id: string, params: SubmitScoreParams): Promise<LeaderboardEntry> {
    return this.client.post<LeaderboardEntry>(`${PREFIX}/${id}`, params);
  }

  around(id: string, playerId: string): Promise<LeaderboardEntry[]> {
    return this.client.get<LeaderboardEntry[]>(`${PREFIX}/${id}/around/${playerId}`);
  }
}
