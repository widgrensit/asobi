#include "AsobiStorage.h"

void UAsobiStorage::Init(UAsobiClient* InClient)
{
	Client = InClient;
}

void UAsobiStorage::ListSaves(const FOnAsobiCloudSaveListResponse& Callback)
{
	Client->Get(TEXT("/api/v1/saves"),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiCloudSave> Saves;
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
								Saves.Add(UAsobiClient::ParseCloudSave(*Obj));
							}
						}
					}
				}
			}
			Callback.ExecuteIfBound(bSuccess, Saves);
		}));
}

void UAsobiStorage::GetSave(const FString& Slot, const FOnAsobiResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/saves/%s"), *Slot), Callback);
}

void UAsobiStorage::PutSave(const FString& Slot, const FString& DataJson, const FOnAsobiResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);

	TSharedPtr<FJsonObject> DataObj;
	TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(DataJson);
	if (FJsonSerializer::Deserialize(Reader, DataObj) && DataObj.IsValid())
	{
		Body->SetObjectField(TEXT("data"), DataObj);
	}
	else
	{
		Body->SetStringField(TEXT("data"), DataJson);
	}

	Client->Put(FString::Printf(TEXT("/api/v1/saves/%s"), *Slot), Body, Callback);
}

void UAsobiStorage::ListStorage(const FString& Collection, const FOnAsobiStorageListResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/storage/%s"), *Collection),
		FOnAsobiResponse::CreateLambda([Callback](bool bSuccess, const FString& Response)
		{
			TArray<FAsobiStorageObject> Objects;
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
								Objects.Add(UAsobiClient::ParseStorageObject(*Obj));
							}
						}
					}
				}
			}
			Callback.ExecuteIfBound(bSuccess, Objects);
		}));
}

void UAsobiStorage::GetStorage(const FString& Collection, const FString& Key, const FOnAsobiResponse& Callback)
{
	Client->Get(FString::Printf(TEXT("/api/v1/storage/%s/%s"), *Collection, *Key), Callback);
}

void UAsobiStorage::PutStorage(const FString& Collection, const FString& Key, const FString& ValueJson, const FOnAsobiResponse& Callback)
{
	TSharedPtr<FJsonObject> Body = MakeShareable(new FJsonObject);

	TSharedPtr<FJsonObject> ValueObj;
	TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(ValueJson);
	if (FJsonSerializer::Deserialize(Reader, ValueObj) && ValueObj.IsValid())
	{
		Body->SetObjectField(TEXT("value"), ValueObj);
	}
	else
	{
		Body->SetStringField(TEXT("value"), ValueJson);
	}

	Client->Put(FString::Printf(TEXT("/api/v1/storage/%s/%s"), *Collection, *Key), Body, Callback);
}

void UAsobiStorage::DeleteStorage(const FString& Collection, const FString& Key, const FOnAsobiResponse& Callback)
{
	Client->Delete(FString::Printf(TEXT("/api/v1/storage/%s/%s"), *Collection, *Key), Callback);
}
