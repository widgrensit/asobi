#include "AsobiEconomy.h"

void UAsobiEconomy::Init(UAsobiClient* InClient)
{
	Client = InClient;
}

void UAsobiEconomy::GetWallets(const FOnAsobiWalletListResponse& Callback)
{
	Client->Get(TEXT("/api/v1/wallets"),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiWallet> Wallets;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					const TArray<TSharedPtr<FJsonValue>>* DataArray;
					if (Json->TryGetArrayField(TEXT("data"), DataArray))
					{
						for (const auto& Val : *DataArray)
						{
							const TSharedPtr<FJsonObject>* Obj;
							if (Val->TryGetObject(Obj))
							{
								Wallets.Add(UAsobiClient::ParseWallet(*Obj));
							}
						}
					}
				}
			}
			Callback.ExecuteIfBound(bSuccess, Wallets);
		}));
}

void UAsobiEconomy::GetWalletHistory(const FString& Currency, const FOnAsobiTransactionListResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/wallets/%s/history"), *Currency),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiTransaction> Transactions;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					const TArray<TSharedPtr<FJsonValue>>* DataArray;
					if (Json->TryGetArrayField(TEXT("data"), DataArray))
					{
						for (const auto& Val : *DataArray)
						{
							const TSharedPtr<FJsonObject>* Obj;
							if (Val->TryGetObject(Obj))
							{
								Transactions.Add(UAsobiClient::ParseTransaction(*Obj));
							}
						}
					}
				}
			}
			Callback.ExecuteIfBound(bSuccess, Transactions);
		}));
}

void UAsobiEconomy::GetStoreListings(const FOnAsobiStoreListingListResponse& Callback)
{
	Client->Get(TEXT("/api/v1/store"),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiStoreListing> Listings;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					const TArray<TSharedPtr<FJsonValue>>* DataArray;
					if (Json->TryGetArrayField(TEXT("data"), DataArray))
					{
						for (const auto& Val : *DataArray)
						{
							const TSharedPtr<FJsonObject>* Obj;
							if (Val->TryGetObject(Obj))
							{
								Listings.Add(UAsobiClient::ParseStoreListing(*Obj));
							}
						}
					}
				}
			}
			Callback.ExecuteIfBound(bSuccess, Listings);
		}));
}

void UAsobiEconomy::Purchase(const FString& ListingId, int32 Quantity, const FOnAsobiResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("listing_id"), ListingId);
	Body->SetNumberField(TEXT("quantity"), Quantity);

	Client->Post(TEXT("/api/v1/store/purchase"), Body, Callback);
}

void UAsobiEconomy::GetInventory(const FOnAsobiInventoryResponse& Callback)
{
	Client->Get(TEXT("/api/v1/inventory"),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiPlayerItem> Items;
			if (bSuccess)
			{
				TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(Response);
				if (Json.IsValid())
				{
					const TArray<TSharedPtr<FJsonValue>>* DataArray;
					if (Json->TryGetArrayField(TEXT("data"), DataArray))
					{
						for (const auto& Val : *DataArray)
						{
							const TSharedPtr<FJsonObject>* Obj;
							if (Val->TryGetObject(Obj))
							{
								Items.Add(UAsobiClient::ParsePlayerItem(*Obj));
							}
						}
					}
				}
			}
			Callback.ExecuteIfBound(bSuccess, Items);
		}));
}

void UAsobiEconomy::ConsumeItem(const FString& ItemId, int32 Quantity, const FOnAsobiResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("item_id"), ItemId);
	Body->SetNumberField(TEXT("quantity"), Quantity);

	Client->Post(TEXT("/api/v1/inventory/consume"), Body, Callback);
}
