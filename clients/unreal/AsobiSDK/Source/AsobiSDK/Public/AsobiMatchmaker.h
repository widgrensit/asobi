#pragma once

#include "CoreMinimal.h"
#include "AsobiClient.h"
#include "AsobiMatchmaker.generated.h"

DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiMatchmakerResponse, bool, bSuccess, const FAsobiMatchmakerTicket&, Ticket);

UCLASS(BlueprintType)
class ASOBISDK_API UAsobiMatchmaker : public UObject
{
	GENERATED_BODY()

public:
	UFUNCTION(BlueprintCallable, Category = "Asobi|Matchmaker")
	void Init(UAsobiClient* InClient);

	// POST /api/v1/matchmaker
	UFUNCTION(BlueprintCallable, Category = "Asobi|Matchmaker")
	void Add(const FString& Mode, const TArray<FString>& Party, const FOnAsobiMatchmakerResponse& Callback);

	// GET /api/v1/matchmaker/:ticket_id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Matchmaker")
	void Status(const FString& TicketId, const FOnAsobiMatchmakerResponse& Callback);

	// DELETE /api/v1/matchmaker/:ticket_id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Matchmaker")
	void Remove(const FString& TicketId, const FOnAsobiResponse& Callback);

private:
	UPROPERTY()
	UAsobiClient* Client = nullptr;
};
