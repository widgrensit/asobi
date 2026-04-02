#pragma once

#include "CoreMinimal.h"
#include "AsobiClient.h"
#include "AsobiEconomy.generated.h"

DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiWalletListResponse, bool, bSuccess, const TArray<FAsobiWallet>&, Wallets);
DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiTransactionListResponse, bool, bSuccess, const TArray<FAsobiTransaction>&, Transactions);
DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiStoreListingListResponse, bool, bSuccess, const TArray<FAsobiStoreListing>&, Listings);
DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiInventoryResponse, bool, bSuccess, const TArray<FAsobiPlayerItem>&, Items);

UCLASS(BlueprintType)
class ASOBISDK_API UAsobiEconomy : public UObject
{
	GENERATED_BODY()

public:
	UFUNCTION(BlueprintCallable, Category = "Asobi|Economy")
	void Init(UAsobiClient* InClient);

	// GET /api/v1/wallets
	UFUNCTION(BlueprintCallable, Category = "Asobi|Economy")
	void GetWallets(const FOnAsobiWalletListResponse& Callback);

	// GET /api/v1/wallets/:currency/history
	UFUNCTION(BlueprintCallable, Category = "Asobi|Economy")
	void GetWalletHistory(const FString& Currency, const FOnAsobiTransactionListResponse& Callback);

	// GET /api/v1/store
	UFUNCTION(BlueprintCallable, Category = "Asobi|Economy")
	void GetStoreListings(const FOnAsobiStoreListingListResponse& Callback);

	// POST /api/v1/store/purchase
	UFUNCTION(BlueprintCallable, Category = "Asobi|Economy")
	void Purchase(const FString& ListingId, int32 Quantity, const FOnAsobiResponse& Callback);

	// GET /api/v1/inventory
	UFUNCTION(BlueprintCallable, Category = "Asobi|Economy")
	void GetInventory(const FOnAsobiInventoryResponse& Callback);

	// POST /api/v1/inventory/consume
	UFUNCTION(BlueprintCallable, Category = "Asobi|Economy")
	void ConsumeItem(const FString& ItemId, int32 Quantity, const FOnAsobiResponse& Callback);

private:
	UPROPERTY()
	UAsobiClient* Client = nullptr;
};
