using Microsoft.AspNetCore.Mvc;
using SampleApi.Models;
using SampleApi.Services;

namespace SampleApi.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class WeatherController : ControllerBase
    {
        private readonly IWeatherService _weatherService;

        public WeatherController(IWeatherService weatherService)
        {
            _weatherService = weatherService;
        }

        [HttpGet]
        public ActionResult<IEnumerable<WeatherForecast>> GetAll()
        {
            var forecasts = _weatherService.GetForecasts(5);
            return Ok(forecasts);
        }

        [HttpGet("{id}")]
        public ActionResult<WeatherForecast> GetById(int id)
        {
            var forecast = _weatherService.GetById(id);
            if (forecast == null)
            {
                return NotFound();
            }
            return Ok(forecast);
        }

        [HttpPost]
        public ActionResult<WeatherForecast> Create([FromBody] WeatherForecast forecast)
        {
            if (forecast == null)
            {
                return BadRequest("Forecast cannot be null.");
            }

            var created = _weatherService.Create(forecast);
            return CreatedAtAction(nameof(GetById), new { id = created.Id }, created);
        }
    }
}
