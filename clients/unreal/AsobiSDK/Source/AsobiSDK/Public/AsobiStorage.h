#pragma once

#include "CoreMinimal.h"
#include "AsobiClient.h"
#include "AsobiStorage.generated.h"

DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiCloudSaveListResponse, bool, bSuccess, const TArray<FAsobiCloudSave>&, Saves);
DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiStorageListResponse, bool, bSuccess, const TArray<FAsobiStorageObject>&, Objects);

UCLASS(BlueprintType)
class ASOBISDK_API UAsobiStorage : public UObject
{
	GENERATED_BODY()

public:
	UFUNCTION(BlueprintCallable, Category = "Asobi|Storage")
	void Init(UAsobiClient* InClient);

	// GET /api/v1/saves
	UFUNCTION(BlueprintCallable, Category = "Asobi|Storage")
	void ListSaves(const FOnAsobiCloudSaveListResponse& Callback);

	// GET /api/v1/saves/:slot
	UFUNCTION(BlueprintCallable, Category = "Asobi|Storage")
	void GetSave(const FString& Slot, const FOnAsobiResponse& Callback);

	// PUT /api/v1/saves/:slot
	UFUNCTION(BlueprintCallable, Category = "Asobi|Storage")
	void PutSave(const FString& Slot, const FString& DataJson, const FOnAsobiResponse& Callback);

	// GET /api/v1/storage/:collection
	UFUNCTION(BlueprintCallable, Category = "Asobi|Storage")
	void ListStorage(const FString& Collection, const FOnAsobiStorageListResponse& Callback);

	// GET /api/v1/storage/:collection/:key
	UFUNCTION(BlueprintCallable, Category = "Asobi|Storage")
	void GetStorage(const FString& Collection, const FString& Key, const FOnAsobiResponse& Callback);

	// PUT /api/v1/storage/:collection/:key
	UFUNCTION(BlueprintCallable, Category = "Asobi|Storage")
	void PutStorage(const FString& Collection, const FString& Key, const FString& ValueJson, const FOnAsobiResponse& Callback);

	// DELETE /api/v1/storage/:collection/:key
	UFUNCTION(BlueprintCallable, Category = "Asobi|Storage")
	void DeleteStorage(const FString& Collection, const FString& Key, const FOnAsobiResponse& Callback);

private:
	UPROPERTY()
	UAsobiClient* Client = nullptr;
};
