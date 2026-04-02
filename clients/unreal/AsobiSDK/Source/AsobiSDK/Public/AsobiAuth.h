#pragma once

#include "CoreMinimal.h"
#include "AsobiClient.h"
#include "AsobiAuth.generated.h"

DECLARE_DYNAMIC_DELEGATE_TwoParams(FOnAsobiAuthResponse, bool, bSuccess, const FAsobiAuthTokens&, Tokens);

UCLASS(BlueprintType)
class ASOBISDK_API UAsobiAuth : public UObject
{
	GENERATED_BODY()

public:
	UFUNCTION(BlueprintCallable, Category = "Asobi|Auth")
	void Init(UAsobiClient* InClient);

	// POST /api/v1/auth/register
	UFUNCTION(BlueprintCallable, Category = "Asobi|Auth")
	void Register(const FString& Username, const FString& Password, const FString& DisplayName, const FOnAsobiAuthResponse& Callback);

	// POST /api/v1/auth/login
	UFUNCTION(BlueprintCallable, Category = "Asobi|Auth")
	void Login(const FString& Username, const FString& Password, const FOnAsobiAuthResponse& Callback);

	// POST /api/v1/auth/refresh
	UFUNCTION(BlueprintCallable, Category = "Asobi|Auth")
	void Refresh(const FString& RefreshToken, const FOnAsobiAuthResponse& Callback);

	// POST /api/v1/auth/oauth
	UFUNCTION(BlueprintCallable, Category = "Asobi|Auth")
	void OAuthAuthenticate(const FString& Provider, const FString& ProviderToken, const FOnAsobiAuthResponse& Callback);

	// POST /api/v1/auth/link (authenticated)
	UFUNCTION(BlueprintCallable, Category = "Asobi|Auth")
	void LinkProvider(const FString& Provider, const FString& ProviderToken, const FOnAsobiResponse& Callback);

	// DELETE /api/v1/auth/unlink (authenticated)
	UFUNCTION(BlueprintCallable, Category = "Asobi|Auth")
	void UnlinkProvider(const FString& Provider, const FOnAsobiResponse& Callback);

	// POST /api/v1/iap/apple (authenticated)
	UFUNCTION(BlueprintCallable, Category = "Asobi|Auth")
	void VerifyAppleIAP(const FString& ReceiptData, const FOnAsobiResponse& Callback);

	// POST /api/v1/iap/google (authenticated)
	UFUNCTION(BlueprintCallable, Category = "Asobi|Auth")
	void VerifyGoogleIAP(const FString& PurchaseToken, const FString& ProductId, const FOnAsobiResponse& Callback);

private:
	void HandleAuthResponse(bool bSuccess, const FString& ResponseBody, const FOnAsobiAuthResponse& Callback);

	UPROPERTY()
	UAsobiClient* Client = nullptr;
};
