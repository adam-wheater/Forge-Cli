using SampleApi.Models;

namespace SampleApi.Services
{
    public interface IWeatherService
    {
        List<WeatherForecast> GetForecasts(int count);
        WeatherForecast? GetById(int id);
        WeatherForecast Create(WeatherForecast forecast);
        bool Delete(int id);
    }
}
