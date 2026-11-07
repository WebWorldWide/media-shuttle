using System.Text.Json;
using System.Text.Json.Serialization;

namespace MediaShuttle.Core;

public sealed class StateStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() }
    };

    // Every toggle in Settings saves on its own, so two saves can overlap; replacing settings.json
    // from both at once fails with "access denied" on Windows. One write at a time.
    private readonly SemaphoreSlim _writeLock = new(1, 1);

    public StateStore(string rootPath)
    {
        RootPath = Path.GetFullPath(rootPath);
        SessionsPath = Path.Combine(RootPath, "sessions");
        Directory.CreateDirectory(SessionsPath);
    }

    public string RootPath { get; }
    public string SessionsPath { get; }
    public string SettingsPath => Path.Combine(RootPath, "settings.json");

    public async Task<AppSettings> LoadSettingsAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(SettingsPath))
        {
            return new AppSettings();
        }

        try
        {
            await using FileStream stream = File.OpenRead(SettingsPath);
            return await JsonSerializer.DeserializeAsync<AppSettings>(stream, JsonOptions, cancellationToken)
                .ConfigureAwait(false) ?? new AppSettings();
        }
        catch (JsonException)
        {
            return new AppSettings();
        }
    }

    public Task SaveSettingsAsync(AppSettings settings, CancellationToken cancellationToken = default) =>
        SaveJsonAtomicAsync(SettingsPath, settings, cancellationToken);

    public string SessionFilePath(TransferSession session) =>
        Path.Combine(SessionsPath, $"{session.StartedUtc:yyyyMMdd-HHmmss}-{session.SessionId[..6]}.json");

    public async Task<string> SaveSessionAsync(TransferSession session, CancellationToken cancellationToken = default)
    {
        string path = SessionFilePath(session);
        await SaveJsonAtomicAsync(path, session, cancellationToken).ConfigureAwait(false);
        return path;
    }

    public async Task<TransferSession?> LoadLatestVerifiedForCardAsync(
        CardInfo card,
        CancellationToken cancellationToken = default)
    {
        // The write time comes back with the directory entry, so ordering by it costs nothing
        // beyond the walk itself; asking the filesystem for it per path afterwards does not.
        foreach (string path in new DirectoryInfo(SessionsPath)
                     .GetFiles("*.json")
                     .OrderByDescending(file => file.LastWriteTimeUtc)
                     .Select(file => file.FullName))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                await using FileStream stream = File.OpenRead(path);
                TransferSession? session = await JsonSerializer.DeserializeAsync<TransferSession>(
                    stream,
                    JsonOptions,
                    cancellationToken).ConfigureAwait(false);
                if (session is null ||
                    !SameRoot(session.SourceRoot, card.RootPath) ||
                    (session.SourceVolumeSerial != 0 &&
                     card.VolumeSerial != 0 &&
                     session.SourceVolumeSerial != card.VolumeSerial))
                {
                    continue;
                }

                return session.Status.Equals("Verified", StringComparison.OrdinalIgnoreCase) &&
                       session.Files.Count > 0
                    ? session
                    : null;
            }
            catch (JsonException)
            {
            }
            catch (IOException)
            {
            }
        }

        return null;
    }

    private async Task SaveJsonAtomicAsync<T>(
        string path,
        T value,
        CancellationToken cancellationToken)
    {
        string directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        string temporaryPath = path + ".tmp-" + Guid.NewGuid().ToString("N");
        await _writeLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using (var stream = new FileStream(
                             temporaryPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             64 * 1024,
                             FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, value, JsonOptions, cancellationToken)
                    .ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            // Antivirus and the search indexer briefly hold a file they have just seen written,
            // which makes the replace fail with "access denied". A short retry rides that out.
            for (int attempt = 1; ; attempt++)
            {
                try
                {
                    File.Move(temporaryPath, path, true);
                    break;
                }
                catch (Exception exception) when (
                    attempt < 5 && exception is UnauthorizedAccessException or IOException)
                {
                    await Task.Delay(40 * attempt, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        finally
        {
            try
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
            }
            finally
            {
                _writeLock.Release();
            }
        }
    }

    private static bool SameRoot(string first, string second) =>
        Path.GetFullPath(first).TrimEnd(Path.DirectorySeparatorChar)
            .Equals(
                Path.GetFullPath(second).TrimEnd(Path.DirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase);
}
