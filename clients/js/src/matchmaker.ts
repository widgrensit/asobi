import { AsobiClient } from "./client.js";
import type { MatchmakerAddParams, MatchmakerTicket } from "./types.js";

const PREFIX = "/api/v1/matchmaker";

export class MatchmakerApi {
  constructor(private client: AsobiClient) {}

  add(params?: MatchmakerAddParams): Promise<MatchmakerTicket> {
    return this.client.post<MatchmakerTicket>(PREFIX, params);
  }

  status(ticketId: string): Promise<MatchmakerTicket> {
    return this.client.get<MatchmakerTicket>(`${PREFIX}/${ticketId}`);
  }

  remove(ticketId: string): Promise<void> {
    return this.client.delete(`${PREFIX}/${ticketId}`);
  }
}
