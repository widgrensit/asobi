import { AsobiClient } from "./client.js";
import type {
  Wallet,
  WalletHistoryParams,
  Transaction,
  StoreItem,
  PurchaseParams,
  PurchaseResult,
  IapReceiptParams,
  IapResult,
} from "./types.js";

const PREFIX = "/api/v1";

export class EconomyApi {
  constructor(private client: AsobiClient) {}

  wallets(): Promise<Wallet[]> {
    return this.client.get<Wallet[]>(`${PREFIX}/wallets`);
  }

  history(currency: string, params?: WalletHistoryParams): Promise<Transaction[]> {
    return this.client.get<Transaction[]>(
      `${PREFIX}/wallets/${currency}/history`,
      params as Record<string, unknown>,
    );
  }

  store(): Promise<StoreItem[]> {
    return this.client.get<StoreItem[]>(`${PREFIX}/store`);
  }

  purchase(params: PurchaseParams): Promise<PurchaseResult> {
    return this.client.post<PurchaseResult>(`${PREFIX}/store/purchase`, params);
  }

  verifyApple(params: IapReceiptParams): Promise<IapResult> {
    return this.client.post<IapResult>(`${PREFIX}/iap/apple`, params);
  }

  verifyGoogle(params: IapReceiptParams): Promise<IapResult> {
    return this.client.post<IapResult>(`${PREFIX}/iap/google`, params);
  }
}
