import { AsobiClient } from "./client.js";
import type { Tournament, TournamentListParams } from "./types.js";

const PREFIX = "/api/v1/tournaments";

export class TournamentsApi {
  constructor(private client: AsobiClient) {}

  list(params?: TournamentListParams): Promise<Tournament[]> {
    return this.client.get<Tournament[]>(PREFIX, params as Record<string, unknown>);
  }

  get(id: string): Promise<Tournament> {
    return this.client.get<Tournament>(`${PREFIX}/${id}`);
  }

  join(id: string): Promise<Record<string, unknown>> {
    return this.client.post(`${PREFIX}/${id}/join`);
  }
}
