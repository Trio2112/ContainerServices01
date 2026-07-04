using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace HelloAzure.Pages;

public class IndexModel : PageModel
{
    private readonly ILogger<IndexModel> _logger;
    private readonly IConfiguration _configuration;

    public string BuildNumber { get; private set; } = string.Empty;
    public DateTimeOffset CurrentTime { get; private set; }
    public string TimeZoneName { get; private set; } = string.Empty;

    public IndexModel(ILogger<IndexModel> logger, IConfiguration configuration)
    {
        _logger = logger;
        _configuration = configuration;
    }

    public void OnGet()
    {
        BuildNumber = _configuration["BUILD_NUMBER"] ?? "local-dev";
        CurrentTime = DateTimeOffset.Now;
        TimeZoneName = TimeZoneInfo.Local.DisplayName;
    }

    // Deliberate test exception — logs to stdout for Azure log inspection practice.
    public IActionResult OnPostLogError()
    {
        var ex = new Exception("Test error triggered by Log Error button.");
        _logger.LogError(ex, "Log Error button clicked - throwing test exception.");
        throw ex;
    }
}
