import { AsobiClient } from "./client.js";
import type {
  RegisterParams,
  LoginParams,
  AuthResponse,
  RefreshResponse,
  OAuthParams,
  LinkProviderParams,
  UnlinkProviderParams,
} from "./types.js";

const PREFIX = "/api/v1/auth";

export class AuthApi {
  constructor(private client: AsobiClient) {}

  async register(params: RegisterParams): Promise<AuthResponse> {
    const res = await this.client.post<AuthResponse>(`${PREFIX}/register`, params);
    this.client.setToken(res.session_token);
    return res;
  }

  async login(params: LoginParams): Promise<AuthResponse> {
    const res = await this.client.post<AuthResponse>(`${PREFIX}/login`, params);
    this.client.setToken(res.session_token);
    return res;
  }

  async refresh(sessionToken: string): Promise<RefreshResponse> {
    const res = await this.client.post<RefreshResponse>(`${PREFIX}/refresh`, {
      session_token: sessionToken,
    });
    this.client.setToken(res.session_token);
    return res;
  }

  oauth(params: OAuthParams): Promise<AuthResponse> {
    return this.client.post<AuthResponse>(`${PREFIX}/oauth`, params);
  }

  link(params: LinkProviderParams): Promise<Record<string, unknown>> {
    return this.client.post("/api/v1/auth/link", params);
  }

  unlink(params: UnlinkProviderParams): Promise<Record<string, unknown>> {
    return this.client.delete("/api/v1/auth/unlink", params);
  }
}
