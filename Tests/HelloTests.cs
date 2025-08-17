using Xunit;

namespace MyApp.Tests
{
    public class HelloTests
    {
        [Fact]
        public void TestAddition()
        {
            Assert.Equal(4, 2 + 2);
        }
    }
}
