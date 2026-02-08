using SampleApi.Models;

namespace SampleApi.Services
{
    public class WeatherService : IWeatherService
    {
        private static readonly string[] Summaries = new[]
        {
            "Freezing", "Bracing", "Chilly", "Cool", "Mild",
            "Warm", "Balmy", "Hot", "Sweltering", "Scorching"
        };

        private readonly List<WeatherForecast> _forecasts = new();
        private int _nextId = 1;

        public List<WeatherForecast> GetForecasts(int count)
        {
            if (count <= 0)
            {
                throw new ArgumentException("Count must be greater than zero.", nameof(count));
            }

            return Enumerable.Range(1, count).Select(index => new WeatherForecast
            {
                Id = index,
                Date = DateOnly.FromDateTime(DateTime.Now.AddDays(index)),
                TemperatureC = Random.Shared.Next(-20, 55),
                Summary = Summaries[Random.Shared.Next(Summaries.Length)]
            }).ToList();
        }

        public WeatherForecast? GetById(int id)
        {
            return _forecasts.FirstOrDefault(f => f.Id == id);
        }

        public WeatherForecast Create(WeatherForecast forecast)
        {
            if (forecast == null)
            {
                throw new ArgumentNullException(nameof(forecast));
            }

            forecast.Id = _nextId++;
            _forecasts.Add(forecast);
            return forecast;
        }

        public bool Delete(int id)
        {
            var forecast = _forecasts.FirstOrDefault(f => f.Id == id);
            if (forecast == null)
            {
                return false;
            }

            _forecasts.Remove(forecast);
            return true;
        }
    }
}
