#include "AsobiAuth.h"

void UAsobiAuth::Init(UAsobiClient* InClient)
{
	Client = InClient;
}

void UAsobiAuth::Register(const FString& Username, const FString& Password, const FString& DisplayName, const FOnAsobiAuthResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("username"), Username);
	Body->SetStringField(TEXT("password"), Password);
	if (!DisplayName.IsEmpty())
	{
		Body->SetStringField(TEXT("display_name"), DisplayName);
	}

	Client->Post(TEXT("/api/v1/auth/register"), Body,
		FOnAsobiResponse::CreateLambda([this, Callback](bool bSuccess, const FString& Response)
		{
			HandleAuthResponse(bSuccess, Response, Callback);
		}));
}

void UAsobiAuth::Login(const FString& Username, const FString& Password, const FOnAsobiAuthResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("username"), Username);
	Body->SetStringField(TEXT("password"), Password);

	Client->Post(TEXT("/api/v1/auth/login"), Body,
		FOnAsobiResponse::CreateLambda([this, Callback](bool bSuccess, const FString& Response)
		{
			HandleAuthResponse(bSuccess, Response, Callback);
		}));
}

void UAsobiAuth::Refresh(const FString& RefreshToken, const FOnAsobiAuthResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("refresh_token"), RefreshToken);

	Client->Post(TEXT("/api/v1/auth/refresh"), Body,
		FOnAsobiResponse::CreateLambda([this, Callback](bool bSuccess, const FString& Response)
		{
			HandleAuthResponse(bSuccess, Response, Callback);
		}));
}

void UAsobiAuth::OAuthAuthenticate(const FString& Provider, const FString& ProviderToken, const FOnAsobiAuthResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("provider"), Provider);
	Body->SetStringField(TEXT("token"), ProviderToken);

	Client->Post(TEXT("/api/v1/auth/oauth"), Body,
		FOnAsobiResponse::CreateLambda([this, Callback](bool bSuccess, const FString& Response)
		{
			HandleAuthResponse(bSuccess, Response, Callback);
		}));
}

void UAsobiAuth::LinkProvider(const FString& Provider, const FString& ProviderToken, const FOnAsobiResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("provider"), Provider);
	Body->SetStringField(TEXT("token"), ProviderToken);

	Client->Post(TEXT("/api/v1/auth/link"), Body, Callback);
}

void UAsobiAuth::UnlinkProvider(const FString& Provider, const FOnAsobiResponse& Callback)
{
	Client->Delete(FString::Printf(TEXT("/api/v1/auth/unlink?provider=%s"), *Provider), Callback);
}

void UAsobiAuth::VerifyAppleIAP(const FString& ReceiptData, const FOnAsobiResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("receipt_data"), ReceiptData);

	Client->Post(TEXT("/api/v1/iap/apple"), Body, Callback);
}

void UAsobiAuth::VerifyGoogleIAP(const FString& PurchaseToken, const FString& ProductId, const FOnAsobiResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);
	Body->SetStringField(TEXT("purchase_token"), PurchaseToken);
	Body->SetStringField(TEXT("product_id"), ProductId);

	Client->Post(TEXT("/api/v1/iap/google"), Body, Callback);
}

void UAsobiAuth::HandleAuthResponse(bool bSuccess, const FString& ResponseBody, const FOnAsobiAuthResponse& Callback)
{
	FAsobiAuthTokens Tokens;

	if (bSuccess)
	{
		TSharedPtr<FJsonObject> Json = UAsobiClient::ParseJson(ResponseBody);
		if (Json.IsValid())
		{
			Json->TryGetStringField(TEXT("access_token"), Tokens.AccessToken);
			Json->TryGetStringField(TEXT("refresh_token"), Tokens.RefreshToken);
			Json->TryGetStringField(TEXT("player_id"), Tokens.PlayerId);

			// Auto-store tokens on the client
			if (Client)
			{
				Client->SetAuthToken(Tokens.AccessToken);
				Client->SetRefreshToken(Tokens.RefreshToken);
				Client->SetPlayerId(Tokens.PlayerId);
			}
		}
	}

	Callback.ExecuteIfBound(bSuccess, Tokens);
}
