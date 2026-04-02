#pragma once

#include "CoreMinimal.h"
#include "AsobiClient.h"
#include "AsobiTournament.generated.h"

DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiTournamentResponse, bool, bSuccess, const FAsobiTournament&, Tournament);
DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiTournamentListResponse, bool, bSuccess, const TArray<FAsobiTournament>&, Tournaments);
DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiNotificationListResponse, bool, bSuccess, const TArray<FAsobiNotification>&, Notifications);

UCLASS(BlueprintType)
class ASOBISDK_API UAsobiTournament : public UObject
{
	GENERATED_BODY()

public:
	UFUNCTION(BlueprintCallable, Category = "Asobi|Tournament")
	void Init(UAsobiClient* InClient);

	// GET /api/v1/tournaments
	UFUNCTION(BlueprintCallable, Category = "Asobi|Tournament")
	void List(const FOnAsobiTournamentListResponse& Callback);

	// GET /api/v1/tournaments/:id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Tournament")
	void Get(const FString& TournamentId, const FOnAsobiTournamentResponse& Callback);

	// POST /api/v1/tournaments/:id/join
	UFUNCTION(BlueprintCallable, Category = "Asobi|Tournament")
	void Join(const FString& TournamentId, const FOnAsobiResponse& Callback);

	// GET /api/v1/notifications
	UFUNCTION(BlueprintCallable, Category = "Asobi|Tournament")
	void GetNotifications(const FOnAsobiNotificationListResponse& Callback);

	// PUT /api/v1/notifications/:id/read
	UFUNCTION(BlueprintCallable, Category = "Asobi|Tournament")
	void MarkNotificationRead(const FString& NotificationId, const FOnAsobiResponse& Callback);

	// DELETE /api/v1/notifications/:id
	UFUNCTION(BlueprintCallable, Category = "Asobi|Tournament")
	void DeleteNotification(const FString& NotificationId, const FOnAsobiResponse& Callback);

private:
	UPROPERTY()
	UAsobiClient* Client = nullptr;
};
