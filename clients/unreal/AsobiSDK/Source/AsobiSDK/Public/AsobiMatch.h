#pragma once

#include "CoreMinimal.h"
#include "AsobiClient.h"
#include "AsobiMatch.generated.h"

DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiMatchResponse, bool, bSuccess, const FAsobiMatchRecord&, Match);
DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiMatchListResponse, bool, bSuccess, const TArray<FAsobiMatchRecord>&, Matches);

UCLASS(BlueprintType)
class ASOBISDK_API UAsobiMatch : public UObject
{
	GENERATED_BODY()

public:
	UFUNCTION(BlueprintCallable, Category = "Asobi|Match")
	void Init(UAsobiClient* InClient);

	// GET /api/v1/matches
	UFUNCTION(BlueprintCallable, Category = "Asobi|Match")
	void List(const FOnAsobiMatchListResponse& Callback);

	// GET /api/v1/matches/:id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Match")
	void Get(const FString& MatchId, const FOnAsobiMatchResponse& Callback);

	// GET /api/v1/players/:id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Match")
	void GetPlayer(const FString& PlayerId, const FOnAsobiResponse& Callback);

	// PUT /api/v1/players/:id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Match")
	void UpdatePlayer(const FString& PlayerId, const FString& DisplayName, const FString& AvatarUrl, const FOnAsobiResponse& Callback);

private:
	UPROPERTY()
	UAsobiClient* Client = nullptr;
};
