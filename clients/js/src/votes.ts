import { AsobiClient } from "./client.js";
import type { Vote } from "./types.js";

export class VotesApi {
  constructor(private client: AsobiClient) {}

  listByMatch(matchId: string): Promise<Vote[]> {
    return this.client.get<Vote[]>(`/api/v1/matches/${matchId}/votes`);
  }

  get(id: string): Promise<Vote> {
    return this.client.get<Vote>(`/api/v1/votes/${id}`);
  }
}
