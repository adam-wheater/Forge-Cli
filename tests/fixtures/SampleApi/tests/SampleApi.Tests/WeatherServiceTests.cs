using SampleApi.Models;
using SampleApi.Services;
using Xunit;

namespace SampleApi.Tests
{
    public class WeatherServiceTests
    {
        private readonly WeatherService _sut;

        public WeatherServiceTests()
        {
            _sut = new WeatherService();
        }

        [Fact]
        public void GetForecasts_WithValidCount_ReturnsCorrectNumber()
        {
            // Arrange
            var count = 5;

            // Act
            var result = _sut.GetForecasts(count);

            // Assert
            Assert.NotNull(result);
            Assert.Equal(count, result.Count);
        }

        [Fact]
        public void GetForecasts_WithZeroCount_ThrowsArgumentException()
        {
            // Arrange & Act & Assert
            Assert.Throws<ArgumentException>(() => _sut.GetForecasts(0));
        }

        [Fact]
        public void GetForecasts_WithNegativeCount_ThrowsArgumentException()
        {
            // Arrange & Act & Assert
            Assert.Throws<ArgumentException>(() => _sut.GetForecasts(-1));
        }

        [Fact]
        public void Create_WithValidForecast_AssignsIdAndStores()
        {
            // Arrange
            var forecast = new WeatherForecast
            {
                Date = DateOnly.FromDateTime(DateTime.Now),
                TemperatureC = 25,
                Summary = "Warm"
            };

            // Act
            var result = _sut.Create(forecast);

            // Assert
            Assert.NotNull(result);
            Assert.True(result.Id > 0);
            Assert.Equal("Warm", result.Summary);
        }

        [Fact]
        public void Create_WithNullForecast_ThrowsArgumentNullException()
        {
            // Arrange & Act & Assert
            Assert.Throws<ArgumentNullException>(() => _sut.Create(null!));
        }

        [Fact]
        public void GetById_AfterCreate_ReturnsCreatedForecast()
        {
            // Arrange
            var forecast = new WeatherForecast
            {
                Date = DateOnly.FromDateTime(DateTime.Now),
                TemperatureC = 30,
                Summary = "Hot"
            };
            var created = _sut.Create(forecast);

            // Act
            var result = _sut.GetById(created.Id);

            // Assert
            Assert.NotNull(result);
            Assert.Equal(created.Id, result.Id);
            Assert.Equal("Hot", result.Summary);
        }

        [Fact]
        public void GetById_WithNonExistentId_ReturnsNull()
        {
            // Arrange & Act
            var result = _sut.GetById(999);

            // Assert
            Assert.Null(result);
        }

        [Fact]
        public void Delete_ExistingForecast_ReturnsTrue()
        {
            // Arrange
            var forecast = new WeatherForecast
            {
                Date = DateOnly.FromDateTime(DateTime.Now),
                TemperatureC = 15,
                Summary = "Cool"
            };
            var created = _sut.Create(forecast);

            // Act
            var result = _sut.Delete(created.Id);

            // Assert
            Assert.True(result);
            Assert.Null(_sut.GetById(created.Id));
        }

        [Fact]
        public void Delete_NonExistentForecast_ReturnsFalse()
        {
            // Arrange & Act
            var result = _sut.Delete(999);

            // Assert
            Assert.False(result);
        }
    }
}
