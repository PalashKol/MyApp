using Microsoft.VisualStudio.TestTools.UnitTesting;
using MyApp;  // reference your app’s namespace

namespace MyApp.Tests
{
    [TestClass]
    public class UnitTest1
    {
        [TestMethod]
        public void TestAddition()
        {
            int a = 2;
            int b = 3;
            int result = a + b;

            Assert.AreEqual(5, result);
        }

        [TestMethod]
        public void TestFailExample()
        {
            Assert.IsTrue("hello".StartsWith("h"));
        }
    }
}
